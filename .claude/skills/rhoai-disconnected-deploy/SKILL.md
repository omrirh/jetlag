---
name: rhoai-disconnected-deploy
description: Run or debug an end-to-end disconnected RHOAI deployment on Performance Lab bare metal via deploy_rhoai_bm.sh. Use when deploying OCP+RHOAI on a lab allocation, resuming a failed deployment, diagnosing mirror/discovery/install failures, or preparing a fresh cloudXX allocation. Covers expected durations, known-benign errors, and recovery recipes for every verified failure mode.
---

# Disconnected RHOAI on Performance Lab Bare Metal

Single entrypoint: `./deploy_rhoai_bm.sh <cloud-id> [flags]` from the repo root on the
**bastion** (first machine of the QUADS allocation). Source of truth for reference
detail: [docs/deploy-mno-rhoai-disconnected.md](../../../docs/deploy-mno-rhoai-disconnected.md).
This skill adds what the doc cannot: operational expectations, verified failure
signatures, and recovery recipes. Prefer running the script over improvising
individual playbooks; prefer `--resume` over restarting from scratch.

## Codebase map — what this branch's code means (groups A–G)

Read this before modifying anything; each group is a semantic unit with its own assumptions.

| Group | Code | Purpose | Load-bearing assumption |
|-------|------|---------|------------------------|
| **A** | `scripts/generate-nodes-override.py`, `ansible/vars/hw-config.yml` (gitignored — holds BMC creds) | QUADS + Redfish → `nodes-override.json`; role + controlplane-NIC selection per hardware model | `hw_controlplane_adapter` **cannot be auto-guessed reliably** — it encodes physical lab cabling. Must be human-verified per allocation (procedure below). Controlplane adapter's MACs are placed first in each node's `mac` list; everything downstream keys off `mac[0]`. |
| **B** | `boot-iso/tasks/dell.yml`, `create-ai-cluster/templates/rhlab_nmstate.yml.j2`, `rhlab*_mac_interface_map.json.j2` | Dell Redfish boot via standard `Boot` PATCH (not SCP XML import); Ignition binds static IPs by **MAC identity** (lowercased), not interface names | MAC-determinism is what makes NIC fixes one-variable changes. Don't reintroduce name-based binding. |
| **C** | `create-inventory/templates/inventory-*.j2` | Lab DNS domain always used for controlplane names in scalelab/performancelab | — |
| **D** | `ansible/roles/bastion-rhoai-services/` | MinIO (:9000/:9001), PyPI cache (:9443), Git cache (:9080/:9081), NFS server (80× pv-100gb exports) | NFS exports at `nfs_export_base` (/var/nfs) — sized for RHOAI PVs, must live on a data disk (group G). |
| **E** | `ansible/roles/sync-operator-index/` (+ templates), parts of `mno-post-cluster-install` | Multi-catalog oc-mirror v2 sync (RHOAI FBC + certified + redhat + community), auto CatalogSources, IDMS/ITMS apply, `image_digest_mirrors` | oc-mirror exit code is non-zero when ANY image fails — see "step 5 marker" below. **Never add registry garbage-collect here** (corrupts multi-arch images on registry 2.8; removed deliberately). |
| **F** | `deploy_rhoai_bm.sh`, `deploy_rhoai_bm_utils.sh`, `credentials.env.example` | Steps 1→7d orchestration, resume logic, vars patching, imageset generation, Jenkins artifacts | Resume checks are **indirect proxies** (file exists / port answers) and can be stale — see Resume semantics. Internal GitLab repos require `GITLAB_TOKEN`. |
| **G** | `ansible/roles/bastion-storage/` | Dedicated disks for `/opt/registry` + `/var/nfs` (`bastion_registry_disk/bastion_nfs_disk: auto`) | Never writes to a disk containing anything (no partitions/signature/mounts). A full RHOAI mirror needs ~500 GB — root disks don't fit it. |

## Preflight checklist (fresh allocation)

1. `credentials.env` in repo root: `GITLAB_TOKEN`, `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`
   (if S3 mirroring), quay.io/rhoai token merged into `pull-secret.txt`.
2. `ansible/vars/all.yml` from `all.rhoai-disconnected-bm.sample.yml`; keep
   `bastion_registry_disk: auto` and `bastion_nfs_disk: auto`.
3. Generate hardware config: `python3 scripts/generate-nodes-override.py --init --cloud <cloudXX>`
   then **verify `hw_controlplane_adapter` — do not trust the guess**:
   - On the bastion find the controlplane NIC: `ip -4 -br addr` → the interface that will
     carry 198.18.0.1 (or already does). Get its MAC: `cat /sys/class/net/<if>/address`.
   - Query the bastion's own iDRAC: `GET /redfish/v1/Systems/System.Embedded.1/NetworkAdapters/<id>/NetworkPorts?$expand=*($levels=1)`
     and find which adapter ID owns that MAC. That adapter ID is the correct value for the
     bastion's model. Nodes of the same model in the same lab are cabled identically.
   - Known-verified mappings (Performance Lab, 2026-07): `r740xd: NIC.Integrated.1`,
     `xe8640: NIC.Slot.1` (its `NIC.Integrated.1`/eno12399* is the **lab** network — same
     pattern as r650/r760). `--init` guessed both wrong once; symptom is the discovery
     timeout described below.
4. Storage sanity: `lsblk` on the bastion — expect ≥1 unused multi-TB disk for the registry.
5. **RHOAI install-sequence drift check**: `install_rhoai()` in `deploy_rhoai_bm_utils.sh` is a
   hand-copied translation of `installRHOAI()` (isRhoai3 branch) in the Jenkins repo
   `gitlab.cee.redhat.com/ods/jenkins`, `vars/disconnectedCluster.groovy`. Script *content*
   auto-propagates (olminstall is cloned fresh each run) but the *orchestration sequence*
   does not. Before a new deployment campaign, diff our operator/configure call sequence
   against the groovy's `sh "./..."` lines and port any added/removed/reordered steps
   (last verified aligned: 2026-07-14, groovy last changed 2026-06-24).

## Canonical command

```bash
./deploy_rhoai_bm.sh <cloudXX> \
  --ocp-version latest-4.XX --ocp-build ga \
  --rhoai-fbc-image quay.io/rhoai/rhoai-fbc-fragment@sha256:<digest> \
  --gpu-operator nvidia \
  --s3-mirror-config <config> --s3-repo <disconnected-s3-git-url> \
  --rhoai-update-channel stable-3.x \
  --add-custom-ca-bundles
```

Flag rules that bite:
- `--ocp-version` is **required** whenever `--rhoai-fbc-image` or `--gpu-operator` is set.
  Omitting it prints only a WARNING ("skipping dependent-operators and catalog digest
  pinning") then crashes later with `yq: cannot match with !!null` (null catalog in the
  nvidia imageset). Keep the flag on every invocation, including resumes.
- `--rhoai-update-channel` *triggers* step 7c — without it RHOAI is never installed even
  with a complete mirror.
- `--refresh-nodes` is not checkpointed: it re-fetches QUADS/Redfish every time it's
  passed. Use it on the first run and after any `hw-config.yml` change; drop it from
  routine resumes.
- After any interruption, re-run the **identical command + `--resume`**.

## Step map, durations, verification

| Step | What | Expected duration | Healthy signal |
|------|------|------------------|----------------|
| 1/1b | venv; optional node refresh | 1–3 min | `mac[0]` per node matches the verified controlplane adapter family |
| 2 | vars patch + inventory | seconds | `ansible/inventory/<cloud>.local` has correct `mac_address=` per node |
| 3 | bastion services | 10–20 min | `curl -sk https://localhost:5000/v2/` answers; `podman ps --filter pod=assisted-service` shows **db, gui, service, image-service** (4 + infra) |
| 4 | OCP release mirror | 20–40 min | `.sync-ocp-done` created |
| 5 | operator index + images mirror | **~2 h first run**; ~25 min delta re-run | `oc-mirror` log shows `images to copy 763`-scale plan; see "expected errors" |
| 6 | cluster install via AI | 40–70 min after discovery | hosts registered within ~5 min of power-cycle; then `installing` → `installed` |
| post | IDMS/ITMS/CatalogSource apply, MCP rollout, `/root/mno/*` artifacts | 10–20 min | `cluster-info.env` written |
| 7a–7d | S3→MinIO, GPU operator, RHOAI, CA bundles | 10–40 min each | CSVs `Succeeded`; DSCI `trustedCABundle` non-empty |

Monitor: `tmux attach -t rhoai-deploy`; deploy logs in `deploy-logs/`;
oc-mirror log: `/opt/registry/sync/operators/rhoai-operator-index/working-dir/logs/oc-mirror-*.log`
(+ `mirroring_errors_*.txt`); AI API: `curl -s localhost:8090/api/assisted-install/v2/clusters`;
AI UI via `ssh -L 8080:localhost:8080 root@<bastion-fqdn>` → http://localhost:8080.

## Resume semantics — and where they lie

Skip conditions (see doc for full table): step 2 = inventory **file exists**; step 3 =
registry **port answers**; steps 4/5 = marker files `.sync-ocp-done`/`.sync-operators-done`;
step 6 = `/root/mno/kubeconfig` exists. Consequences:

- Changing node data (`hw-config.yml`, allocation) does NOT invalidate step 2 —
  `rm ansible/inventory/<cloud>.local` to force regeneration.
- A stopped registry makes resume re-run ALL of setup-bastion (step 3). Don't stop the
  registry while a resume might run.
- Markers are written only on playbook success. oc-mirror exits non-zero if ANY image
  fails, but `allowed_mirror_failure_patterns` (`sync-operator-index` defaults, patched by
  `deploy_rhoai_bm.sh` with the known-benign set below) makes the playbook itself tolerate
  those specific failures and still succeed — the step-5 marker is written automatically,
  no manual `touch` needed. A genuinely new/unmatched error still fails the playbook and
  blocks the marker: investigate before adding it to the allow-list or touching the marker
  by hand.
- Step 3's port check cannot see dead assisted-service containers (see failure playbook).

## Expected mirror errors — do not chase

At RHOAI 3.5 / 763 images, ≥753 copied is a healthy run. Known-benign failures (enforced
automatically via `allowed_mirror_failure_patterns`, not just operator judgment):

- `rhaii/vllm-{cpu,cuda,gaudi,rocm,spyre}-rhel9` — `manifest unknown`: digests referenced
  by the rhods-operator bundle **do not exist upstream** (stale FBC refs). Unfixable
  locally. Knock-on: `rhoai/odh-operator-bundle` "skipped because related image failed".
- `nvidia/gpu-operator-bundle` — missing `.sig` on registry.connect.redhat.com.
- `mariadb:10.11.8` — upstream registry rate limit (transient; usually clears on re-run).
- `context deadline exceeded` writing blobs — transient; delta re-run completes them.

Anything OUTSIDE this list is a real regression — investigate before proceeding.

## Failure playbook (verified signatures)

**Disk full (`no space left on device` during mirror)** — should be impossible with
`bastion_registry_disk: auto`; if hit, check `df -h /opt/registry /` and `lsblk`. After ANY
ENOSPC also check the assisted-service pod (next item) — its containers die quietly.
Never "clean up" with registry garbage-collect (next-but-one item).

**`Connection refused ... :8090 /v2/clusters` at cluster create** — assisted-service
containers died earlier (classically during ENOSPC) and podman removed them; the pod still
shows "Running" with only db+gui. Fix (2 min, no marker changes):
```bash
podman ps --filter pod=assisted-service   # missing: service, image-service
ansible-playbook -i ansible/inventory/<cloud>.local /dev/stdin <<'EOF'
- hosts: bastion
  vars_files: [ansible/vars/lab.yml, ansible/vars/all.yml]
  roles: [bastion-assisted-installer]
EOF
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8090/api/assisted-install/v2/clusters  # → 200
```

**`manifest blob unknown: blob unknown to registry` on push, with planning reporting
`size=0B`** — registry metadata/blob-store inconsistency (historically caused by
`garbage-collect --delete-untagged`, now removed; never reintroduce). Repair one repo:
```bash
rm -rf /opt/registry/data/docker/registry/v2/repositories/<repo>
podman restart bastion-registry   # clears stale descriptor cache
oc image mirror -a /opt/registry/pull-secret-bastion.txt <src> <bastion>:5000/<repo> --keep-manifest-list
```
Scan for more damage: walk `/v2/_catalog` tags; for each manifest-list tag, HEAD every
child digest; 404 children = gutted repo. Release payloads are also referenced by digest —
HEAD every digest from `oc adm release info --pullspecs` against `ocp4/openshift4`.

**`yq: cannot match with !!null` right after imageset generation** — `--ocp-version`
missing from the command. Re-run with it restored.

**Discovery timeout (`Wait up to 40 min for nodes to be discovered`, 0 hosts)** — the #1
time sink; diagnose in this order (~10 min, no reboots):
1. Did BMCs stream the ISO? `podman logs httpd | grep discovery.iso | awk '{print $1}' | sort | uniq -c`
   — expect every node's mgmt IP (`getent hosts mgmt-<node>`). ~300 MB then silence is
   NORMAL for a booted node (lazy virtual-media reads); a missing BMC = that node is slow
   in POST or needs a BMC reset (docs/troubleshooting.md).
2. Console screenshot without leaving the bastion (Dell):
   ```bash
   curl -sk -u <bmc_user>:<bmc_pass> -X POST -H "Content-Type: application/json" \
     -d '{"FileType":"ServerScreenShot"}' \
     https://<bmc>/redfish/v1/Dell/Managers/iDRAC.Embedded.1/DellLCService/Actions/DellLCService.ExportServerScreenShot \
     | python3 -c "import json,base64,sys; open('shot.png','wb').write(base64.b64decode(json.load(sys.stdin)['ServerScreenShotFile']))"
   ```
3. If the console shows RHCOS at a login prompt with an IP: `ping <node-198.18-ip>` from
   the bastion. **Unreachable = the IP is on a NIC not cabled to the controlplane VLAN**
   → wrong `hw_controlplane_adapter` for that model. Fix hw-config.yml (verify via the
   preflight procedure), then clean re-do:
   ```bash
   # stop deploy (Ctrl+C), then:
   curl -s -X DELETE localhost:8090/api/assisted-install/v2/infra-envs/<infraenv-id>
   curl -s -X DELETE localhost:8090/api/assisted-install/v2/clusters/<cluster-id>
   rm ansible/inventory/<cloud>.local
   ./deploy_rhoai_bm.sh <cloud> --resume --refresh-nodes <same flags...>
   ```
   Success signal: hosts register within ~5 min of power-cycle.

**Step 5 playbook failed and mirror log shows errors NOT in the known-benign list** —
that's the only case requiring manual intervention now (the benign set is tolerated
automatically). Verify `mirroring_errors_*.txt`, and if the new error is genuinely
benign, add its pattern to `allowed_mirror_failure_patterns` in `deploy_rhoai_bm.sh`
(and to the "Expected mirror errors" list above) rather than one-off `touch
.sync-operators-done`, so future runs tolerate it too.

## Success criteria & Jenkins handoff

Deployment is complete when `/root/mno/` contains `kubeconfig` (untouched `system:admin`
client-cert, internal API URL — for Jetlag's own steps and local QE use),
`jenkins-kubeconfig` (a derived copy: server patched to `https://<bastion-fqdn>:6443`,
bearer token baked in — for Jenkins), `kubeadmin-password`, `cluster-info.env` (the stable
Jenkins interface — `CLUSTER_API_URL`, `CLUSTER_APPS_DOMAIN`, `BASTION_FQDN`,
`JENKINS_KUBECONFIG_PATH`, …), registry CA manifests; and on-cluster: all nodes `Ready`,
`gpu-operator*` and `rhods-operator*` CSVs `Succeeded`, DSCI
`spec.trustedCABundle.customCABundle` non-empty. Jenkins consumes `cluster-info.env`
directly and reaches the API via the bastion HAProxy — no cluster-network access needed.
