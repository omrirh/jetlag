# Jetlag — Disconnected RHOAI Automation: Tasks

## Recently Completed

| Item | What was done |
|------|--------------|
| `run_s3_mirror()` credential fix | `s3-to-s3` subcommand requires `--source-access-key`/`--source-secret-key` flags; env vars `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` are not picked up by `get_env_or_arg()` for this subcommand. Fixed by passing them explicitly as CLI flags. MinIO target credentials now passed as `--target-access-key`/`--target-secret-key` from `${MINIO_USERNAME:-minioadmin}` / `${MINIO_PASSWORD:-minioadmin}`. |
| `run_s3_mirror()` Python fix | `disconnected-s3` requires Python ≥ 3.11; bastion `.ansible` venv runs 3.9. Fixed by installing `python3.11` via dnf if absent and calling `poetry env use python3.11` before `poetry sync`. `pip install --user` also replaced with `pip install` (fails inside a venv). |
| `credentials.env.example` | Added `MINIO_USERNAME`/`MINIO_PASSWORD` with defaults matching `bastion-rhoai-services` role (`minioadmin`/`minioadmin`). Documents override path when `minio_username`/`minio_password` are changed in `ansible/vars/all.yml`. |
| S3 mirror (M-4) | `all-smoke` config fully mirrored to bastion MinIO: `ods-ci-s3` (3.6 GiB), `ods-ci-wisdom` (8.6 GiB), `rhoai-dw` (11 MiB), 3× empty buckets. AWS credentials sourced from Vault `apps/rhods-ci/aws/rhods-jenkins`. |
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

### J-1 — ✅ DONE — Emit `cluster-info.env` at the end of `deploy.sh` step 6

**Implemented** in `deploy.sh` post-deploy section. Reads `cluster_name` and `base_dns_name` from the inventory file, writes `/root/mno/cluster-info.env` with:

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

### J-2 — ✅ DONE — Patch the kubeconfig `server:` field to the bastion FQDN

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

### J-4 — ✅ DONE — Add NFS server setup to `bastion-rhoai-services` role

**Implemented** in `ansible/roles/bastion-rhoai-services/tasks/main.yml` (NFS section) and defaults. Enabled by default (`setup_bastion_nfs: true`). Creates 80 export dirs at `/var/nfs/pv-100gb-{1..80}` owned by `nfsnobody`, writes `/etc/exports` scoped to `controlplane_network`, enables and starts `nfs-server`.

---

### J-5 — ✅ EVALUATED / DEFERRED — MariaDB service for cluster metadata tracking

**Decision:** Not needed in the Jetlag disconnected flow. The `cluster-info.env` file (J-1) provides the stable key→value interface that Jenkins and operators need (API URL, apps domain, kubeconfig path). MariaDB in the reference automation is a TestOps inventory database; that concern is out of scope for Jetlag's deployment automation layer.

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

### J-15 — Add NFS StorageClass + PersistentVolumes to post-deploy step

The `bastion-rhoai-services` Ansible role creates 80 NFS export directories on the bastion and starts `nfs-server`, but never creates the corresponding OpenShift `StorageClass` or `PersistentVolume` objects. As a result, any PVC that requests dynamic or static NFS storage (e.g. `model-catalog-postgres`) stays Pending indefinitely.

**Steps to implement in `deploy_rhoai_bm.sh` post-deploy section:**
1. Create a `StorageClass` named `nfs-bastion` (no provisioner — static binding):
```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-bastion
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Retain
```
2. Create 80 `PersistentVolume` objects pointing to `<bastion-ip>:/var/nfs/pv-100gb-{1..80}`, each 100Gi RWO/RWX, `storageClassName: nfs-bastion`.

**Skip condition for `--resume`:** `oc get sc nfs-bastion` returns 0.

**Unblocks:** `model-catalog-postgres` PVC binding → AI Hub model catalog → `LLMInferenceService` postgres backend.

---

### J-16 — Create RHOAI DataConnection for bastion MinIO after S3 mirror

After `run_s3_mirror()` (step 7a) completes, no `DataConnection` (Kubernetes Secret with `data-connection` label) is created in RHOAI pointing to the bastion MinIO instance. Without this, users cannot create model servers or pipelines that reference S3 storage.

**Status:** M-4 (S3 mirror) is now complete — bastion MinIO has all 6 `all-smoke` buckets populated. This task is the immediate next step (M-5).

**Steps to implement at the end of `run_s3_mirror()`:**
```bash
oc create secret generic dc-bastion-minio \
  -n redhat-ods-applications \
  --from-literal=AWS_ACCESS_KEY_ID=${MINIO_USERNAME:-minioadmin} \
  --from-literal=AWS_SECRET_ACCESS_KEY=${MINIO_PASSWORD:-minioadmin} \
  --from-literal=AWS_S3_ENDPOINT=https://${BASTION_FQDN}:9000 \
  --from-literal=AWS_DEFAULT_REGION=us-east-1 \
  --from-literal=AWS_S3_BUCKET=<mirrored-bucket-name> \
  --dry-run=client -o yaml \
| oc label --local -f - opendatahub.io/dashboard=true \
    opendatahub.io/managed=true \
    app.kubernetes.io/part-of=data-science-project \
| oc apply -f -
```
Bucket name should be derived from the `--s3-mirror-config` value or made configurable via a new `--s3-bucket` flag.

**Skip condition for `--resume`:** Secret `dc-bastion-minio` exists in `redhat-ods-applications`.

---

### J-17 — Fix malformed NFS `/etc/exports` network (Jinja2 list rendering bug)

`controlplane_network` is stored as a single-element Python list `['198.18.0.0/16']` in
Jetlag's generated inventory files. The `bastion-rhoai-services` role default passes it
directly into the template:

```yaml
# ansible/roles/bastion-rhoai-services/defaults/main/main.yml
nfs_export_network: "{{ controlplane_network | default('0.0.0.0/0') }}"
```

Jinja2 renders the list repr literally, producing:
```
/var/nfs/pv-100gb-1 ['198.18.0.0/16'](rw,sync,no_subtree_check,no_root_squash)
```

The NFS server treats `['198.18.0.0/16']` as a hostname — no client matches it and all
NFS mounts return `access denied`.

**Observed on cloud54:** discovered when `model-catalog-postgres` pod reached
`MountVolume.SetUp failed: exit status 32` after the StorageClass/PV issue (J-15) was
resolved. Fixed manually with `sed -i "s/\['\(.*\)'\]/\1/g" /etc/exports && exportfs -ra`.

**Fix:** normalize `controlplane_network` to a plain CIDR string in the defaults:

```yaml
# ansible/roles/bastion-rhoai-services/defaults/main/main.yml
nfs_export_network: >-
  {{ controlplane_network[0]
     if (controlplane_network is iterable and controlplane_network is not string)
     else controlplane_network | default('0.0.0.0/0') }}
```

This handles both the list form (`['198.18.0.0/16']`) and any future inventory that
defines `controlplane_network` as a plain string.

**Files to change:**
- `ansible/roles/bastion-rhoai-services/defaults/main/main.yml` — `nfs_export_network` default (1 line)

**Test:** after the fix, `/etc/exports` on a fresh bastion should contain bare CIDRs:
```
/var/nfs/pv-100gb-1 198.18.0.0/16(rw,sync,no_subtree_check,no_root_squash)
```
and worker nodes in that subnet must be able to mount without `access denied`.

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

### J-9 — ✅ Resolved: DNS strategy for external consumers

**Decision:** Use a **Squid proxy on the bastion** (J-X below). This is the exact
pattern the reference disconnected automation uses (`squid_http_proxy` /
`squid_https_proxy` in `cluster-details.yaml`) and it is directly portable to the
Performance Lab environment:

- No external DNS zone or dnsmasq exposure needed.
- The bastion's local dnsmasq already resolves `*.apps.mno.<base_dns_name>` to the
  internal HAProxy VIP. Squid on the bastion inherits this resolution.
- Jenkins agents (on the corporate network) can reach the bastion IP directly, so
  `HTTPS_PROXY=http://bastion-fqdn:3128` in the agent gives full app-route access
  without any `/etc/hosts` modification or DNS delegation.
- `api.mno.<base_dns_name>` does not need proxy resolution — the kubeconfig
  `server:` is already patched to the bastion FQDN (J-2), so `oc` calls go direct.

**Implemented by:** J-X (deploy `bastion-proxy` role).

---

### J-X — ✅ DONE — Deploy Squid proxy on bastion via `bastion-proxy` role

The `bastion-proxy` Ansible role already exists in Jetlag and deploys a Squid
proxy container (port 3128). Enabling it on the bastion lets Jenkins agents route
app-route traffic through the bastion's DNS, which resolves `*.apps.mno.<domain>`
to the internal HAProxy VIP.

**What:**
1. Call the `bastion-proxy` role from `bastion-rhoai-services` or `setup-bastion.yml`
   when `setup_bastion_proxy: true` (new var, default `false`).
2. Open TCP port 3128 in the bastion firewall (`firewalld` or `iptables` rule in
   the role).
3. Emit `SQUID_HTTP_PROXY` and `SQUID_HTTPS_PROXY` in `/root/mno/cluster-info.env`
   (format: `http://<bastion-fqdn>:3128`) so Jenkins can consume them without
   hardcoding the bastion address.

**Defaults to add:**
```yaml
setup_bastion_proxy: false
```

**Unblocks (Jenkins):**
[JS-3](jenkins_todos.md#js-3--route-app-route-traffic-through-bastion-squid-proxy) —
Jenkins pipeline configures `HTTPS_PROXY` from the kubeconfig `server:` field;
Squid must be running and reachable on port 3128.

---

### J-18 — Add `registry.stage.redhat.io` credentials and `rhaii` imageset coverage

All `LLMInferenceServiceConfig` objects installed by RHOAI 3.4 reference images from `registry.redhat.io/rhaii/` (`vllm-cuda-rhel9`, `vllm-rocm-rhel9`, `vllm-gaudi-rhel9`, `vllm-spyre-rhel9`, `vllm-cpu-rhel9`). These images are **not yet promoted to production** — they exist only on `registry.stage.redhat.io/rhaii/`. The production registry returns "manifest unknown" for their digests; the stage registry returns "unauthorized" because the bastion pull-secret does not include stage registry credentials.

**Root cause (confirmed via internal Jira):** The `rhaii` namespace requires Customer Portal credentials for `registry.stage.redhat.io`. The UHC pool token in `pull-secret.txt` is scoped to `registry.redhat.io` only. The fix used in the Jenkins pipeline is a `registries.conf` redirect: `registry.redhat.io/rhaii` → `registry.stage.redhat.io/rhaii`, with stage credentials present.

**Two-part fix:**

1. **Pull-secret**: add `registry.stage.redhat.io` auth entry with Customer Portal credentials (Red Hat SSO login, not a service account token) to `pull-secret.txt`.

2. **Imageset automation**: add to `sync_rhoai_registries_conf()` in `deploy_rhoai_bm_utils.sh` (alongside the existing `rhoai.conf` entry):
```toml
# /etc/containers/registries.conf.d/rhaii.conf
[[registry]]
location="registry.redhat.io/rhaii"
[[registry.mirror]]
location="registry.stage.redhat.io/rhaii"
```
Then add `rhaii/vllm-cuda-rhel9` (and CPU/ROCm/Gaudi/Spyre variants as needed) to the `additional_images` list in the disconnected-imageset so `oc-mirror` picks them up and pushes them to the local bastion registry. Add a corresponding IDMS entry `registry.redhat.io/rhaii` → `bastion:5000/rhaii`.

**Impact:** Without this fix, `LLMInferenceService` objects using any GPU accelerator (NVIDIA CUDA, AMD ROCm, Intel Gaudi, IBM Spyre) will fail to pull the serving image in a disconnected environment.

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
| J-9 (DNS strategy) | ✅ resolved by | J-X (Squid proxy on bastion) |
| J-X (deploy `bastion-proxy`, open port 3128) | unblocks | JS-3 (Jenkins proxy config) |
| J-17 (NFS exports malformed CIDR) | blocks | NFS mounts from all worker nodes on fresh deployments |
