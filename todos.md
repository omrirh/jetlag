# Jetlag RHOAI/llm-d Disconnected BM — Open Tasks

## Completed

| Item | Detail |
|------|--------|
| `bastion-rhoai-services` role | Containerized Minio (9000/9001), PyPI cache (9443), Git cache (9080/9081); gated by `setup_bastion_rhoai_services: true` in `ansible/vars/all.yml` |
| `populate_rhoai_images()` in `deploy.sh` | Clones `disconnected-imageset` at runtime, merges `additional_images` from rhoai-ci + rhoai-{version} + dependent-operators + custom-images; deduplicates |
| `clone_disconnected_imageset()` | Clone/pull via `GITLAB_TOKEN` env var; `--imageset-repo <url>` overrides the default GitLab URL |
| Catalog digest pinning | `catalogs_to_sync[].catalog` pinned to `@sha256:` digests from `ocp-digests.yaml` |
| `sync_rhoai_registries_conf` | Writes `registries.conf.d/rhoai.conf` so `oc-mirror` resolves `registry.redhat.io/rhoai → quay.io/rhoai`; auto-set to `true` when `--rhoai-fbc-image` is passed |
| `image_tag_mirrors` / `image_digest_mirrors` | Vars added to `sync-operator-index` role for IDMS/ITMS injection |
| `--rhoai-fbc-image` flag in `deploy.sh` | Drives full disconnected-imageset automation when provided |
| `ignore_errors: true` on oc-mirror task | Ansible continues to catalog-sources.yaml generation even when oc-mirror exits non-zero (DNS-1035 cosmetic error on digest-pinned catalog names) |
| CatalogSource tag selection fixed | Role now filters bastion registry tags by `operator_index_tag` prefix (e.g. `v4.19*`) instead of blindly taking `tags[0]` (which is oldest on re-syncs) |
| `catalog_source_name` field in `catalogs_to_sync` | Role template uses this to generate standard OLM names (`redhat-operators`, `community-operators`) so RHOAI-managed dependency subscriptions resolve on fresh deploys |
| `operator_index_tag` derived from `--ocp-version` | `patch_rhoai_vars()` computes `v4.19` from `latest-4.19` and patches `sync-operator-index.yml` automatically |
| Post-deployment IDMS/ITMS/CatalogSource apply | `deploy.sh` post-step applies mirror manifests from `working-dir/cluster-resources/` after Step 6 and waits for MCP rollout |
| J-8 — Registry CA applied to cluster | `bastion-registry-ca` ConfigMap in `openshift-config`; `image.config.openshift.io/cluster` patched with `additionalTrustedCA`; DSCI `trustedCABundle.managementState: Managed` inherits automatically |
| RHOAI operator installed | CSV `rhods-operator.3.4.0-ea.2` Succeeded in `redhat-ods-operator`; 3 operator pods running |

---

## Known Broken State (current/last environment)

The environment used during the last session is likely disposed. The following issues were active at the time of disposal and must be resolved on the next fresh deployment:

- **`servicemeshoperator3.v3.1.0` not mirrored**: RHOAI operator hardcodes `startingCSV: servicemeshoperator3.v3.1.0` in its managed subscription, but only v3.3.2 was in the bastion catalog. `minVersion: 3.1.0` added to `sync-operator-index.yml` but sync was NOT re-run before environment disposal.
- **`GatewayConfig default-gateway` not ready**: sail-operator (OSSM 3.x) not installed because the above subscription was `ConstraintsNotSatisfiable`. The `networking.istio.io/v1` CRD was missing.
- **DSC Dashboard/ModelRegistry blocked**: `default-dsc` reported `gateway domain is missing` for Dashboard and ModelRegistry components — downstream consequence of the gateway not being ready.

---

## Next Immediate Steps (in order)

### J-10 — Re-run sync to mirror `servicemeshoperator3.v3.1.0` (BLOCKER)

RHOAI operator hardcodes `startingCSV: servicemeshoperator3.v3.1.0` in the subscription it manages. The `minVersion: 3.1.0` constraint was added to `sync-operator-index.yml` but the sync has not been re-run. Until this runs, sail-operator cannot install and `GatewayConfig` will not become ready.

```bash
ansible-playbook -i ansible/inventory/<cloud>.local ansible/sync-operator-index.yml
```

After sync, watch the subscription resolve:
```bash
oc get subscription servicemeshoperator3 -n openshift-operators -w
oc get csv -n openshift-operators | grep servicemeshoperator3
```

### J-11 — Verify sail-operator installs and Istio is functional (BLOCKER, depends on J-10)

After `servicemeshoperator3.v3.1.0` is in the bastion catalog:
1. OLM should install the CSV automatically via the RHOAI-managed subscription.
2. Check that `DestinationRule` CRD exists and `GatewayConfig` becomes ready:
   ```bash
   oc get crd destinationrules.networking.istio.io
   oc get gatewayconfig default-gateway -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
   ```
3. If `GatewayConfig` does not self-heal, an `Istio` CR with revision `openshift-gateway` may be required (sail-operator v3.x pattern).

### J-12 — DSC Dashboard/ModelRegistry (depends on J-11)

`default-dsc` reports `gateway domain is missing` for Dashboard and ModelRegistry. Unblocks automatically once `GatewayConfig.Status.Domain` is populated (which happens after J-11). No manual action anticipated — just verify after J-11.

### 3 — Emit `cluster-info.env` + patch kubeconfig (J-1, J-2)

Post-deploy contract artifacts that Jenkins consumes to reach the cluster externally:
- `cluster-info.env` — `CLUSTER_API_URL`, `CLUSTER_APPS_DOMAIN`, `BASTION_FQDN`,
  `KUBECONFIG_PATH`, `KUBEADMIN_PASSWORD_PATH`
- patched `kubeconfig` — `server:` rewritten to `https://<bastion-fqdn>:6443`

**J-2 is blocked on:** TLS strategy decision (CA bundle in kubeconfig vs.
`insecure-skip-tls-verify`).

### 4 — Full e2e smoke test

Once J-10 through J-12 are resolved on a fresh environment:
```bash
export GITLAB_TOKEN=<token>
./deploy.sh <cloud-id> \
  --ocp-version latest-4.19 \
  --rhoai-fbc-image quay.io/rhoai/rhoai-fbc-fragment@sha256:f7fe40ead9b1fca93b7626a3db97780577478379f1734d2f40a5ac24be233705 \
  --ocp-build ga
```
Set `setup_bastion_rhoai_services: true` in `ansible/vars/all.yml` to include Minio/PyPI/Git
cache in the bastion setup (Step 3).

**Verify at each step:**
- Step 2: `sync-operator-index.yml` has `@sha256:` catalogs, `operator_index_tag: v4.19`, and 90+ `additional_images`
- Step 3: Minio (`:9000`), PyPI cache (`:9443`), Git cache (`:9080`) reachable on bastion
- Step 4: OCP release images in bastion registry
- Step 5: `oc-mirror` completes; `catalog-sources.yaml` present in `working-dir/cluster-resources/`
- Step 6: `oc get nodes` shows all nodes Ready; IDMS/ITMS/CatalogSource applied automatically
- Post: `servicemeshoperator3.v3.1.0` CSV Succeeded; `GatewayConfig` Ready; DSC all components Managed

---

## Open — Jenkins side (blocked on TLS strategy)

- [ ] Decide TLS strategy: cluster CA in kubeconfig vs. `insecure-skip-tls-verify` (unblocks J-2)
- [ ] Confirm Jenkins agents have `sudo` (needed for `/etc/hosts` injection)
- [ ] Add JobParams: `KUBECONFIG` (secret file), `BASTION_FQDN`, `CLUSTER_APPS_DOMAIN`
- [ ] Add pipeline preamble: inject `api.mno.<domain>` + app routes → resolved `BASTION_IP`
      into `/etc/hosts` on agent
- [ ] Document final param/preamble contract in `docs/deploy-mno-rhoai-disconnected.md`

---

## Deferred

| ID | Item | Status |
|----|------|--------|
| J-1 | Emit `cluster-info.env` at end of `deploy.sh` step 6 | Pending TLS strategy |
| J-2 | Patch kubeconfig `server:` to bastion FQDN | Blocked on TLS strategy decision |
| J-3 | Document deployment outputs in `docs/` | After J-1 + J-2 done |
| J-4 | NFS server in `bastion-rhoai-services` | Needs storage decision |
| J-5 | MariaDB for cluster metadata | Needs TestOps decision |
| J-6 | `Error: bad expression` in `dependent-operators/generate.sh` | Upstream issue in disconnected-imageset; cosmetic only |
| J-7 | Missing `rhoai-3.4.EA2` dir in disconnected-imageset | Blocked on upstream update |
| J-9 | Refactor `deploy.sh` into `lib/` modules | Pure refactor, no logic changes |
| J-13 | Extend `populate_rhoai_images()` to merge `operators[]` from companion imagesets (e.g. `servicemesh-3.1.0`) into `sync-operator-index.yml` | Currently mitigated by static `minVersion: 3.1.0` in vars |
| J-14 | Clean up duplicate CatalogSources left from manual patching (`redhat-operator-index`, `community-operator-index` alongside new `redhat-operators`, `community-operators`) | Cosmetic; won't block installs on fresh deploy |

**J-9 design:** split helper functions from `deploy.sh` into three sourced files under `lib/`:
- `lib/common.sh` — `die`, `usage`, `check_step_done`, `should_skip`, `print_sync_summary`
- `lib/imageset.sh` — `clone_disconnected_imageset`, `find_rhoai_version_dir`, `populate_rhoai_images`
- `lib/vars.sh` — `patch_yaml_scalar`, `patch_rhoai_vars`, `patch_nodes_override`

`deploy.sh` becomes ~150 lines of globals + arg parsing + step orchestration; `lib/` holds the building blocks.

---

## Background: Why `redhat-operators` CatalogSource Must Use Standard Names

RHOAI operator reconciles the `servicemeshoperator3` subscription continuously and hardcodes `source: redhat-operators`. This cannot be overridden — any manual patch reverts on the next reconcile cycle. The solution is to ensure a CatalogSource named exactly `redhat-operators` exists in the cluster pointing to the correct bastion registry content. The `catalog_source_name` field in `catalogs_to_sync` now handles this automatically on fresh deploys.

## Background: `disconnected-imageset/servicemesh-3.1.0/` and Our Automation Gap

The disconnected-imageset repo contains a dedicated `servicemesh-3.1.0/` imageset directory that pins `servicemeshoperator3` to `minVersion: 3.1.0 maxVersion: 3.1.0`. Our `populate_rhoai_images()` function only extracts `additionalImages[]` from generate scripts — it does NOT process `operators[]` entries in companion imagesets. The `servicemesh-3.1.0` operator pin is therefore invisible to our automation and must be maintained manually in `sync-operator-index.yml` (currently done via the `minVersion: 3.1.0` entry). J-13 tracks the longer-term fix.
