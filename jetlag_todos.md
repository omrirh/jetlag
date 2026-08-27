# Jetlag — Disconnected RHOAI Automation: Tasks

## Recently Completed

| Item | What was done |
|------|--------------|
| `run_s3_mirror()` credential fix | `s3-to-s3` subcommand requires `--source-access-key`/`--source-secret-key` flags; env vars `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` are not picked up by `get_env_or_arg()` for this subcommand. Fixed by passing them explicitly as CLI flags. MinIO target credentials now passed as `--target-access-key`/`--target-secret-key` from `${MINIO_USERNAME:-minioadmin}` / `${MINIO_PASSWORD:-minioadmin}`. |
| `run_s3_mirror()` Python fix | `disconnected-s3` requires Python ≥ 3.11; bastion `.ansible` venv runs 3.9. Fixed by installing `python3.11` via dnf if absent and calling `poetry env use python3.11` before `poetry sync`. `pip install --user` also replaced with `pip install` (fails inside a venv). |
| `credentials.env.example` | Added `MINIO_USERNAME`/`MINIO_PASSWORD` with defaults matching `bastion-rhoai-services` role (`minioadmin`/`minioadmin`). Documents override path when `minio_username`/`minio_password` are changed in `ansible/vars/all.yml`. |
| S3 mirror (M-4) | `all-smoke` config fully mirrored to bastion MinIO: `ods-ci-s3` (3.6 GiB), `ods-ci-wisdom` (8.6 GiB), `rhoai-dw` (11 MiB), 3× empty buckets. AWS credentials sourced from Vault `apps/rhods-ci/aws/rhods-jenkins`. |
| `bastion-rhoai-services` role | Containerized Minio (9000/9001), PyPI cache (9443), Git cache (9080/9081) via `setup_bastion_rhoai_services: true` in `setup-bastion.yml` |
| `populate_rhoai_images()` in `deploy_rhoai_bm.sh` | Clones `disconnected-imageset` at runtime, merges `additional_images` from rhoai-ci + rhoai-{version} + dependent-operators + custom-images into `sync-operator-index.yml`; pins catalog digests |
| `clone_disconnected_imageset()` | Authenticated clone/pull of disconnected-imageset via `GITLAB_TOKEN` env var |
| `sync_rhoai_registries_conf` | Writes `registries.conf.d/rhoai.conf` mirror entry so `oc-mirror` resolves `registry.redhat.io/rhoai → quay.io/rhoai` |
| `image_tag_mirrors` / `image_digest_mirrors` | Vars added to `sync-operator-index` role and documented in sample vars |
| Catalog digest pinning | `catalogs_to_sync[].catalog` for redhat/community-operator-index replaced with `@sha256:` digests from `ocp-digests.yaml` |
| `allowed_mirror_failure_patterns` (J-20) | Allow-lists specific `oc-mirror` failures observed not to affect deployment health, so sync no longer hard-fails on them |
| `patch_jenkins_kubeconfig_token()` (J-21) | Bakes a bearer token (minted via internal API login) into a dedicated `/root/mno/jenkins-kubeconfig`, avoiding the oauth-openshift DNS-resolution failure external `oc login` hits, without touching the canonical `/root/mno/kubeconfig` |
| Handing off cluster access (docs) | New section in `docs/deploy-mno-rhoai-disconnected.md` templating the `/etc/hosts` + credentials handoff for QE members accessing OCP/RHOAI consoles from local environments |
| `operator_index_name` in `all.yml` (cloud07, 2026-08-25) | Added the missing key directly to `ansible/vars/all.yml` so `mno-post-cluster-install` picks up the real mirrored index (`rhoai-operator-index`) instead of its `redhat-operator-index` fallback default. Root cause (item below) not yet fixed at the source. |
| Kube-burner SA idempotency fix (2026-08-25) | `mno-post-cluster-install/tasks/main.yml` "Add kube-burner sa" used `oc create sa kubeburner`, which errors `already exists` on any retry after a partial prior run. Changed to `oc create --dry-run=client -o yaml \| oc apply -f -`. |
| RHOAI channel mismatch preflight (2026-08-25) | `install_rhoai()` in `deploy_rhoai_bm_utils.sh` now checks `--rhoai-update-channel` against the live `PackageManifest` for `rhods-operator` in the target CatalogSource before installing anything, and `die`s with the actually-available channels. Previously a mismatch between `--rhoai-update-channel` (install-side) and `--rhoai-channel` (mirror-side, step 5) just hung on `Waiting for installPlan...` for a fixed retry budget then errored with no indication of the real cause. See `.claude/skills/rhoai-disconnected-deploy/SKILL.md` failure playbook for the recovery recipe if hit on an un-patched checkout. |
| Mirror allow-list additions (cloud07, 2026-08-25) | Added `"unexpected EOF"` and `"openshift-serverless-1/serverless-operator-bundle"` to `allowed_mirror_failure_patterns` in `deploy_rhoai_bm.sh` — same transient-CDN-blip class as the existing `context deadline exceeded` entry, just a different Go HTTP error string; the bundle entry is a knock-on skip of the related image. Flagged in the skill as "not yet verified safe to ignore" (unlike the older, confirmed-cosmetic entries) — watch for serverless-operator/KServe issues on future runs. |

## Follow-up — found this session, not yet fixed at the source

Discovered debugging a live cloud07 RHOAI 3.5.0 deployment (2026-08-25). Worked around
live where noted; none of these are blocking, but each will recur on a future
deployment under the right conditions.

| Item | Problem | Suggested fix |
|------|---------|----------------|
| `patch_yaml_scalar()` silent no-op | It's a `sed` substitution on an existing line — silently does nothing if the target key isn't already present in the file, no error. This is the actual root cause of the `operator_index_name` bug above: `all.rhoai-disconnected-bm.sample.yml` has no placeholder line for it, so `deploy_rhoai_bm.sh`'s own auto-patch (`deploy_rhoai_bm.sh:276-281`) has been silently failing on *every* RHOAI disconnected run, not just this one. | Add an `operator_index_name: ""` placeholder line to the sample template, or make `patch_yaml_scalar` append the key when absent instead of no-op. |
| Step 6 resume-check too coarse | `check_step_done` step 6 is just `[[ -f kubeconfig ]]`. `mno-post-cluster-install` (last role in `mno-deploy.yml`) writes kubeconfig early in its own task list, then has ~15 more tasks (IDMS/ITMS/CatalogSource, AAP, gitops, LSO, ODF, monitoring, PAO). If it dies anywhere after kubeconfig retrieval, `--resume` sees step 6 as done and never re-enters the role — permanently. | Split kubeconfig retrieval into its own earlier marker, or check a stronger completion signal (e.g. `idms-operator-0` or DSC existence) for step 6. |
| Step 7 resume-check has the same gap | `check_step_done` step 7 only checks `idms-operator-0` exists. The `rhoai-catalog-dev` CatalogSource alias is created later in the *same* conditional block — if IDMS succeeds but the alias creation is interrupted, a later `--resume` skips the whole block forever, and step 10 fails since olminstall hardcodes `source: rhoai-catalog-dev`. | Check `oc get catalogsource rhoai-catalog-dev` too, or split into separate steps. |
| `mno-post-cluster-install`'s multi-catalog `when` logic | "Apply oc mirror catalogSource on bastion registry clusters" (`~line 171`, guarded by `when: not catalog_sources_stat.exists`) ran even though the mutually-exclusive sibling task (`when: catalog_sources_stat.exists`) had just succeeded moments earlier in the same play — confirmed via a direct `stat` module call that `exists: true` was correct. Routed around with `--start-at-task` rather than fixed; root cause not identified. | Reproduce in a minimal playbook to isolate whether it's a `register`/fact-scoping issue or the two tasks were never meant to coexist without an intervening boundary. |
| Runtime-only facts (`ai_cluster_id`, `openshift_version`) | Set via `set_fact` in `create-ai-cluster`/`ocp-release` and never persisted anywhere. Any future "just re-run this one broken role standalone" recovery has to manually rediscover them (this session: queried the AI API directly for `ai_cluster_id`, derived `openshift_version` from `ocp_release_version` by hand). | Persist both to a generated vars file (e.g. `ansible/vars/runtime-facts.yml`) written once after the roles that set them, sourced by later roles and ad-hoc recovery plays. |
| Audit for more bare `oc create` calls | The kube-burner SA fix (above) was found by hitting it on a retry, not by inspection — there could be sibling non-idempotent `oc create` calls elsewhere in `mno-post-cluster-install`/`sno-post-cluster-install` not yet exercised by an actual resume. | Grep both roles for `oc create` (vs `oc apply`) and convert to the same `--dry-run=client -o yaml \| oc apply -f -` pattern proactively. |
| `/dev/stdin` ad-hoc playbook pattern is broken | SKILL.md's existing "Connection refused" recovery recipe (`ansible-playbook -i ... /dev/stdin <<'EOF' ... roles: [bastion-assisted-installer] ... EOF`) resolves `vars_files:` **and** `roles:` relative paths against `/dev` (stdin's pseudo-directory), not the invocation cwd — confirmed directly: a plain `cluster_type` var came back undefined through this exact pattern. As documented, that recipe would fail with "role not found" and/or silently-undefined vars. | Replace the `/dev/stdin` heredoc in SKILL.md with the working pattern from this session: write to a real temp file inside `ansible/` (e.g. `ansible/_adhoc-<name>.yml`), run it, `rm` it after. |
| `bastion-storage` "auto" mode + multi-VD hosts | On a freshly-allocated Performance Lab r750 with an unconfigured PERC controller, "auto" found nothing (no VDs existed at all — a real prerequisite step, not currently covered by any preflight doc or automation). Separately, once two VDs exist, "auto" processes `registry` before `nfs` in `bastion_storage_volumes` and always grabs the *largest* unused disk — would hand the big NFS-sized volume to the registry instead, since registry is checked first. Worked around by setting `bastion_registry_disk`/`bastion_nfs_disk` to explicit device paths. | Document the RAID-VD-creation prerequisite in the preflight checklist; consider a size-aware or explicitly-ordered `bastion_storage_volumes` default so "auto" doesn't need to be avoided on multi-VD hosts. |

---

## Motivation

After `deploy_rhoai_bm.sh` finishes, the cluster is fully operational but reachable only
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

### J-1 — ✅ DONE — Emit `cluster-info.env` at the end of `deploy_rhoai_bm.sh` step 6

**Implemented** in `deploy_rhoai_bm.sh` post-deploy section. Reads `cluster_name` and `base_dns_name` from the inventory file, writes `/root/mno/cluster-info.env` with:

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

### J-2 — ✅ DONE — Patch a dedicated kubeconfig for external (Jenkins) consumption

**Implemented** as `patch_jenkins_kubeconfig_server()` in `deploy_rhoai_bm_utils.sh`,
called in the post-deploy phase of every run against `/root/mno/jenkins-kubeconfig`
— a copy of `/root/mno/kubeconfig` made fresh on every run (see J-21). The canonical
`/root/mno/kubeconfig` is never touched, so Jetlag's own post-install steps and
local QE cluster administration on the bastion keep non-expiring `system:admin`
client-cert access. For each cluster entry in `jenkins-kubeconfig` it:

1. Rewrites `server:` to `https://<bastion-fqdn>:6443` (bastion HAProxy forwards
   6443 to the cluster API; the FQDN is publicly resolvable).
2. Sets `insecure-skip-tls-verify: true` and **removes**
   `certificate-authority-data` — the API TLS cert is issued for
   `api.<cluster>.*`, not the bastion FQDN, so verification would always fail
   (this resolves the former JS-4 TLS-strategy question in favor of skip-verify).
3. Idempotent: skips when `server:` already points at the bastion FQDN.

`jenkins-kubeconfig` is Jenkins-ready as-is: `oc whoami`, `bareMetalBastionProxy`
(which derives the bastion FQDN from the kubeconfig `server:` field), and
everything downstream work without VPN access to the cluster network.

**Unblocks (Jenkins):**
[JS-2](jenkins_todos.md#js-2--add-jobparams) — `jenkins-kubeconfig` is the only
auth artifact Jenkins needs; no pipeline-side server-URL rewrite required.

---

### J-3 — ✅ DONE — Document deployment outputs in `docs/deploy-mno-rhoai-disconnected.md`

**Implemented** in the "Deployment Outputs" section of `docs/deploy-mno-rhoai-disconnected.md`. Documents all artifacts written to `/root/mno/` including kubeconfig, kubeadmin password, `cluster-info.env` (full schema with all keys), registry CA manifests, and image config patch.

---

---

### J-4 — ✅ DONE — Add NFS server setup to `bastion-rhoai-services` role

**Implemented** in `ansible/roles/bastion-rhoai-services/tasks/main.yml` (NFS section) and defaults. Enabled by default (`setup_bastion_nfs: true`). Creates 80 export dirs at `/var/nfs/pv-100gb-{1..80}` owned by `nfsnobody`, writes `/etc/exports` scoped to `controlplane_network`, enables and starts `nfs-server`.

---

### J-5 — ✅ EVALUATED / DEFERRED — MariaDB service for cluster metadata tracking

**Decision:** Not needed in the Jetlag disconnected flow. The `cluster-info.env` file (J-1) provides the stable key→value interface that Jenkins and operators need (API URL, apps domain, kubeconfig path). MariaDB in the reference automation is a TestOps inventory database; that concern is out of scope for Jetlag's deployment automation layer.

---

### J-6 — Investigate `Error: bad expression` in `dependent-operators/generate.sh`

During `populate_rhoai_images()` in `deploy_rhoai_bm.sh`, the `dependent-operators/generate.sh`
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

`find_rhoai_version_dir()` in `deploy_rhoai_bm.sh` maps the RHOAI version derived from the FBC
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

The `bastion-rhoai-services` role creates 80 NFS export dirs and starts `nfs-server`, but never creates the corresponding OpenShift `StorageClass` or `PersistentVolume` objects. Any PVC requesting NFS storage (e.g. `model-catalog-postgres`) stays Pending indefinitely.

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

### J-17 — ✅ DONE — Fix malformed NFS `/etc/exports` network (Jinja2 list rendering bug)

**Implemented** in `ansible/roles/bastion-rhoai-services/defaults/main/main.yml`. `nfs_export_network` now normalises `controlplane_network` from its list form `['198.18.0.0/16']` to a bare CIDR string, preventing NFS `access denied` on all worker nodes.

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
  `deploy_rhoai_bm.sh` step 7 (post-install)?

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

### J-19 — Mirror openldap image for RHOAI test identity provider

RHOAI test setup (via olminstall/ods-ci) deploys an OpenLDAP pod used as an identity provider. The image is pulled from a personal quay.io namespace:

```
quay.io/rh-ee-jstetina/openldap-ocp@sha256:10233fef19f10b1b7d48f85e71faa064b98f422a984c522a86607ab35e56d21c
```

In a disconnected environment this pull fails with `ImagePullBackOff` since quay.io is unreachable.

**Next step:** talk to Jakub (jstetina) about image access and whether there is a plan to promote this to an official registry location.

**Fix:** once access/location is confirmed, add to `additional_images` in the imageset config so the image lands in the bastion registry before olminstall runs.

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

### J-20 — ✅ DONE — Tolerate specific `oc-mirror` failures that haven't affected deployment health

**Problem:** `oc mirror --v2` exits non-zero when *any* image fails to copy, even though it continues mirroring everything else and still generates the cluster-resources manifests. A handful of images consistently fail to mirror, which was hard-blocking the entire deployment even though — as observed across RHOAI/llm-d runs to date — their absence has not affected cluster or workload health.

**Decision:** allow-list these specific failures so the sync step doesn't hard-fail on them, rather than block deployment on images with no immediate fix. This is a pragmatic call based on what's been *observed* so far, not a claim that these are permanently unfixable or unimportant — if any of them is ever found to cause a real deployment or test failure, it should be pulled off the allow-list and root-caused properly at that point.

**Implemented:**
- `ansible/roles/sync-operator-index/defaults/main.yml` — new `allowed_mirror_failure_patterns: []` var (empty = any error is fatal, preserving original behavior).
- `ansible/roles/sync-operator-index/tasks/main.yml` — the mirror task now runs with `failed_when: false`, collects the run's `mirroring_errors_*.txt`, and fails only if an error line doesn't match one of the allowed regex patterns (or if rc≠0 but no error report is found at all — fail-closed default).
- `deploy_rhoai_bm.sh` — writes 5 tolerated-failure patterns into `sync-operator-index.yml` for every RHOAI run:
  - `registry.redhat.io/rhaii/vllm-*`: bundle references digests deleted upstream (FBC defect — fails on connected clusters too; llm-d tests use their own vllm images).
  - `rhoai/odh-operator-bundle`: knock-on skip; checked later by the 7c RHODS CSV check.
  - `nvidia/gpu-operator-bundle`: missing upstream `.sig`; checked later by 7b — if 7b fails, mirror it manually with `--remove-signatures`.
  - `docker-registry1.mariadb.com` / `context deadline exceeded`: transient network errors; complete on later re-runs.
- `deploy_rhoai_bm.sh` also propagates `operator_index_name` from `sync-operator-index.yml` into `all.yml`, since `mno-deploy.yml` (step 6) only loads `all.yml` — without this, post-install would fall back to the role default (`redhat-operator-index`) and apply cluster-resources from a working-dir that doesn't exist.

**Unblocks:** Step 5 (sync operator index) completing reliably instead of hard-failing on images with no immediate fix.

**Revisit if:** any of the allow-listed patterns is ever observed to correlate with an actual RHOAI/llm-d deployment or test failure.

---

### J-21 — ✅ DONE — Bake a bearer token into a dedicated Jenkins kubeconfig

**Problem:** Jenkins-side tooling (ods-ci) performs its own `oc login -u kubeadmin -p ... <api-url>` against the OAuth server, which requires resolving `oauth-openshift.apps.<cluster>.<base_dns_name>` — a route only the bastion's local dnsmasq can resolve. From outside the lab network this fails with `dial tcp: lookup ...: no such host`, even with the patched kubeconfig (J-2) and Squid proxy (J-X) already in place.

**Implemented** as `patch_jenkins_kubeconfig_token()` in `deploy_rhoai_bm_utils.sh`, called in the post-deploy phase before `patch_jenkins_kubeconfig_server`. `deploy_rhoai_bm.sh` first copies `/root/mno/kubeconfig` to `/root/mno/jenkins-kubeconfig` on every run (fresh copy each time, so the baked-in token is never older than the current pass), then, since the bastion itself sits inside the lab network and resolves `api.<cluster>.<base_dns_name>` natively:
1. Logs in via the internal API URL with kubeadmin/password (`--insecure-skip-tls-verify=true` — the internal API cert isn't in the bastion's trust store), into a throwaway `KUBECONFIG`.
2. Extracts the resulting bearer token with `oc whoami -t`.
3. Rewrites `jenkins-kubeconfig`'s `users[].user` to `{token: ...}`, replacing the client-certificate credentials. `/root/mno/kubeconfig` itself is never touched.

This lets Jenkins authenticate directly against the API server (which validates bearer tokens itself), with no oauth-openshift route lookup involved — regardless of which `EXTERNAL_AUTH_METHOD` the Jenkins job uses. Identity is `kube:admin` (the OAuth-issued kubeadmin identity), deliberately kept rather than swapped for a dedicated ServiceAccount token — some ods-ci quality-gate tests (`OCPLogin.robot`) drive the actual OCP console login form via Selenium, which needs a real username/password-backed identity; an SA token has no such login flow at all. Console/dashboard UI login itself is handled separately — see [Handing off cluster access](docs/deploy-mno-rhoai-disconnected.md#handing-off-cluster-access) in the docs (`/etc/hosts` entries for apps-domain routes + the real kubeadmin username/password, or a Jenkins/RHOAI-pipeline-provisioned `htpasswd-cluster-admin` IDP where required — provisioning that IDP is outside Jetlag's scope).

Idempotent in the sense that re-running is always safe, but not skip-on-already-patched: because `jenkins-kubeconfig` is recopied from the untouched original every run, this always re-logs-in and mints a fresh token (cheap, bastion-local). Fails soft (warns, leaves client-cert auth in place) if the internal login doesn't succeed.

**Caveat:** the token has the default OpenShift OAuth lifetime (~24h). A `jenkins-kubeconfig` reused well past that window (without Jetlag re-running) will start seeing 401s from Jenkins — a separate expiry case, not a recurrence of the DNS issue. Re-running `deploy_rhoai_bm.sh --resume` refreshes it.

**Unblocks (Jenkins):** ods-ci `oc login` failures such as `Unable to connect to the server: dial tcp: lookup oauth-openshift.apps.<cluster>...: no such host`.

---

## Cross-Reference Summary

| This task | Status | Notes |
|-----------|--------|-------|
| J-6 (`bad expression` in generate.sh) | ⏳ upstream | Cosmetic; fix in `disconnected-imageset` repo |
| J-7 (missing rhoai version dir) | ⏳ upstream | Resolves automatically once upstream adds the GA directory |
| J-8 (registry CA for DSCI) | ⏳ open | Manifests generated and applied to cluster; DSCI `spec.trustedCABundle` wiring unconfirmed |
| J-15 (NFS StorageClass + PVs) | ⏳ open | Bastion NFS exports ready; OCP objects not yet created by automation |
| J-16 (DataConnection for MinIO) | ⏳ open | Not created after S3 mirror step |
| J-18 (rhaii imageset + stage credentials) | ⏳ open | GPU serving images missing from disconnected imageset |
