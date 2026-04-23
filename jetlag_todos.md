# Jetlag — Disconnected RHOAI Automation: Tasks

## Recently Completed

| Item | What was done |
|------|--------------|
| `bastion-rhoai-services` role | Containerized Minio (9000/9001), PyPI cache (9443), Git cache (9080/9081) via `setup_bastion_rhoai_services: true` in `setup-bastion.yml` |
| `populate_rhoai_images()` in `deploy.sh` | Clones `disconnected-imageset` at runtime, merges `additional_images` from rhoai-ci + rhoai-{version} + dependent-operators + custom-images into `sync-operator-index.yml`; pins catalog digests |
| `clone_disconnected_imageset()` | Authenticated clone/pull of disconnected-imageset via `GITLAB_TOKEN` env var |
| `sync_rhoai_registries_conf` | Writes `registries.conf.d/rhoai.conf` mirror entry so `oc-mirror` resolves `registry.redhat.io/rhoai → quay.io/rhoai` |
| `image_tag_mirrors` / `image_digest_mirrors` | Vars added to `sync-operator-index` role and documented in sample vars |
| Catalog digest pinning | `catalogs_to_sync[].catalog` for redhat/community-operator-index replaced with `@sha256:` digests from `ocp-digests.yaml` |

---

## Motivation

After `deploy.sh` finishes, the cluster is fully operational but reachable only
from within the bastion host. The bastion's HAProxy already forwards `:6443`,
`:443`, and `:80` from its public IP to the cluster — no HAProxy changes are needed.

The gap is on the Jetlag output side:

1. The kubeconfig written to `/root/mno/kubeconfig` has `server:` pointing at the
   cluster's internal API IP. A Jenkins agent outside the bastion cannot use that
   address; it needs the bastion's public FQDN instead.
2. There is no machine-readable artifact that tells an external consumer where the
   API and app routes live after a deployment completes. Jenkins must be told
   `CLUSTER_APPS_DOMAIN` to inject the right entries into `/etc/hosts`.
3. The location and schema of deployment outputs are not documented, so Jenkins
   admins have no stable reference for what Jetlag produces and where to find it.

Fixing all three makes the Jetlag output self-contained and consumable by Jenkins
without any human-in-the-loop hand-off or SSH access to the bastion.

---

## Action Items

### J-1 — Emit `cluster-info.env` at the end of `deploy.sh` step 6

Write a file at `/root/mno/cluster-info.env` after the cluster is up, containing:

```bash
CLUSTER_API_URL=https://<bastion-fqdn>:6443
CLUSTER_APPS_DOMAIN=apps.mno.<base_dns_name>
BASTION_FQDN=<bastion-fqdn>
KUBECONFIG_PATH=/root/mno/kubeconfig
KUBEADMIN_PASSWORD_PATH=/root/mno/kubeadmin-password
```

Values are derivable at deploy time: bastion FQDN and `base_dns_name` from the
Ansible inventory and `all.yml`.

The file serves as the stable interface between the Jetlag deployment and any
consumer (Jenkins, TestOps, manual operator). Jenkins reads `CLUSTER_APPS_DOMAIN`
from it; the remaining fields are available for future automation without
re-running or modifying Jetlag.

**Unblocks (Jenkins):**
[JS-2](jenkins_todos.md#js-2--add-jobparams) — `CLUSTER_APPS_DOMAIN` can be
sourced from this file instead of being entered manually per job run.

---

### J-2 — Patch the kubeconfig `server:` field to the bastion FQDN

After the cluster kubeconfig is written to `/root/mno/kubeconfig`, rewrite the
`server:` line from the internal cluster API IP to `https://<bastion-fqdn>:6443`.

```bash
BASTION_FQDN=$(hostname -f)   # or read from inventory
yq e ".clusters[].cluster.server = \"https://${BASTION_FQDN}:6443\"" \
  -i /root/mno/kubeconfig
```

The kubeconfig is then usable by Jenkins as-is: the bastion FQDN is publicly
resolvable, and Jenkins can derive `BASTION_IP` from it in the preamble without
any explicit IP param.

The TLS configuration embedded in the kubeconfig (CA bundle vs. skip-verify) is
determined by the outcome of
[JS-4](jenkins_todos.md#js-4--decide-on-tls-strategy); implement whichever option
is chosen there.

**Blocked by (Jenkins):**
[JS-4](jenkins_todos.md#js-4--decide-on-tls-strategy) — TLS strategy must be
decided before the kubeconfig patch step can be finalized.

**Unblocks (Jenkins):**
[JS-2](jenkins_todos.md#js-2--add-jobparams) — the patched kubeconfig is the only
auth artifact Jenkins needs; no pipeline-side server-URL rewrite required.

---

### J-3 — Document deployment outputs in `docs/deploy-mno-rhoai-disconnected.md`

Add a section titled **"Deployment Outputs"** to
`docs/deploy-mno-rhoai-disconnected.md` that describes every artifact `deploy.sh`
writes after a successful run, so Jenkins admins and operators have a stable
reference without reading the script.

Minimum content:

| Artifact | Path on bastion | Description |
|----------|----------------|-------------|
| Kubeconfig | `/root/mno/kubeconfig` | Cluster admin kubeconfig; `server:` patched to bastion FQDN (after J-2) |
| kubeadmin password | `/root/mno/kubeadmin-password` | Plaintext cluster admin password |
| Cluster info | `/root/mno/cluster-info.env` | Machine-readable env file with API URL, apps domain, and artifact paths (after J-1) |

Include the full schema of `cluster-info.env` (all keys and their meaning) and
note which fields Jenkins consumes and how.

**Depends on:** J-1 and J-2 implemented so the documented behaviour matches the
actual output.

**Unblocks (Jenkins):**
[JS-5](jenkins_todos.md#js-5--document-the-jenkins-paramspreamble-contract) — the
Jenkins contract doc can cross-reference this section rather than duplicating the
output schema.

---

---

### J-4 — Add NFS server setup to `bastion-rhoai-services` role

The disconnected-cluster reference automation sets up an NFS server on the bastion
with 80 export directories (`/var/nfs/pv-100gb-{1..80}`) to back OpenShift
PersistentVolumes. Jetlag currently has no equivalent.

Evaluate whether RHOAI workloads in the disconnected Jetlag environment require
NFS-backed PVs (vs. ODF, local-storage, or other storage backends). If so, add
NFS server setup to `ansible/roles/bastion-rhoai-services/tasks/main.yml` following
the disconnected-cluster pattern:

- Install and start `nfs-server`
- Create `nfsnobody` user/group
- Create export directories under `/var/nfs/`
- Template `/etc/exports` and run `exportfs -arv`

---

### J-5 — Evaluate MariaDB service for cluster metadata tracking

The disconnected-cluster reference runs a containerized MariaDB on port 9306 on the
bastion to store cluster connection details (API, console, Minio, registry URLs,
credentials). This is a TestOps workflow for programmatic cluster inventory.

Evaluate whether the same cluster-metadata tracking is needed in the Jetlag
disconnected flow. If so, add a MariaDB container task to
`ansible/roles/bastion-rhoai-services/` gated behind its own boolean var
(e.g. `setup_bastion_mariadb | default(false)`).

---

### J-6 — Investigate `Error: bad expression` in `dependent-operators/generate.sh`

During `populate_rhoai_images()` in `deploy.sh`, the `dependent-operators/generate.sh`
emits 3 `Error: bad expression, please check expression syntax` messages. The `isc.yaml`
output is still correct (digests are properly substituted), so this has not blocked any
test runs so far. However the root cause is unconfirmed and may silently affect other
OCP versions.

**Suspected root cause:** `get_ocp_versions()` in `lib/utils.sh` (line ~207) uses
`yq e '.[env(OCP_IMAGE)] | keys[]'`, which uses a jq-style `keys[]` expression that
may not be valid in Go yq v4. If this call fails, the versioned-image loop in
`set_ocp_digests()` is skipped entirely. The correct digest is still written because the
unversioned fallback (`s|redhat-operator-index-digest|...|`) handles the template.
The 3 errors likely correspond to the 3 `ocp_images` entries queried in the versioned loop.

**To investigate:**
1. Run `OCP_VERSION=4.19 /usr/local/bin/yq e '.[env(OCP_IMAGE)] | keys[]' resources/ocp-digests.yaml`
   from within `/tmp/disconnected-imageset/` with `OCP_IMAGE=redhat-operator-index-digest` to
   confirm whether Go yq v4.40.3 accepts the expression.
2. If invalid: upstream fix in `disconnected-imageset/lib/utils.sh` (not a Jetlag-owned file).
   A workaround would be to set `OCP_VERSION` before calling `generate.sh` so the versioned
   loop is unnecessary (the unversioned fallback already handles the template correctly).

**Impact:** None observed so far. The 3 errors are cosmetic as long as no template uses the
versioned placeholder form `redhat-operator-index-digest-v4.XX` (the current v4.19 template
uses the unversioned form).

---

### J-7 — Handle missing `rhoai-{version}` directory in disconnected-imageset

`find_rhoai_version_dir()` in `deploy.sh` maps the RHOAI version derived from the FBC
image (e.g. `3.4.0-ea.2`) to the corresponding `imagesets/v2/rhoai-3.4.EA2` directory in
the cloned `disconnected-imageset` repo. When the directory doesn't exist (e.g. only
`rhoai-3.4.EA1` is present), the function logs a warning and skips version-specific images.

**Current behaviour (acceptable):** A warning is emitted and the version-specific workbench
and framework images are omitted from `additional_images`. The sync still proceeds but
will not mirror workbench notebook images for that RHOAI release.

**To fix when the upstream repo is updated:**
- Verify `rhoai-3.4.EA2` (or the GA directory for 3.4) is added to `disconnected-imageset`
  after the EA2 → GA transition.
- No code change needed in Jetlag; `find_rhoai_version_dir()` already handles the directory
  lookup automatically once the directory exists upstream.

---

### J-8 — Provide bastion registry CA cert to DSCI (disconnected RHOAI install)

The RHOAI `DataScienceClusterInitialization` (DSCI) resource needs to trust the bastion's
self-signed registry CA so that RHOAI components can pull images from
`<bastion-fqdn>:5000` without TLS errors.

**Steps to implement:**
1. Locate the bastion registry CA on the bastion host (typically
   `/opt/registry/certs/domain.crt`).
2. Create a `ConfigMap` in `openshift-config` namespace with the CA bundle.
3. Patch the cluster-wide `image.config.openshift.io/cluster` object to add the registry
   host under `spec.additionalTrustedCA`.
4. Reference the CA bundle in the DSCI `spec.trustedCABundle` field (or confirm the
   cluster-level trust propagates automatically to RHOAI operators).

**Open questions:**
- Does setting `additionalTrustedCA` on the cluster image config suffice for RHOAI, or
  does DSCI require an explicit `spec.trustedCABundle`?
- Should this be added to `bastion-rhoai-services`, a new role, or handled inline in
  `deploy.sh` step 7 (post-install)?

---

## Cross-Reference Summary

| This task | Relationship | Jenkins task |
|-----------|-------------|--------------|
| J-1 (emit `cluster-info.env`) | unblocks | JS-2 (`CLUSTER_APPS_DOMAIN` auto-sourced) |
| J-2 (patch kubeconfig `server:`) | blocked by | JS-4 (TLS strategy decision) |
| J-2 (patch kubeconfig `server:`) | unblocks | JS-2 (kubeconfig usable directly) |
| J-3 (document deployment outputs) | unblocks | JS-5 (Jenkins contract doc can cross-reference) |
| J-6 (`bad expression` in generate.sh) | upstream issue | disconnected-imageset repo |
| J-7 (missing rhoai version dir) | upstream issue | disconnected-imageset repo |
| J-8 (registry CA for DSCI) | unblocks | RHOAI disconnected install |
