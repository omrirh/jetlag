# Disconnected OCP for RHOAI / llm-d Deployment on Performance Lab

This document describes how this Jetlag fork is adapted for deploying a **disconnected bare-metal OpenShift cluster on Performance Lab** to run **Red Hat OpenShift AI (RHOAI) with llm-d** as part of the OpenShift AI test suite.

> **Before reading this document**, familiarize yourself with the standard Performance Lab MNO deployment guide:
> [docs/deploy-mno-performancelab.md](deploy-mno-performancelab.md)
>
> This document only covers what is **specific to this use case**.

---

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Vars Files](#vars-files)
- [RHOAI Image Automation](#rhoai-image-automation)
- [Node & Hardware Configuration](#node--hardware-configuration)
- [deploy\_rhoai\_bm.sh — End-to-End Entrypoint](#deploy_rhoai_bmsh--end-to-end-entrypoint)
  - [Usage](#usage)
  - [CLI Arguments](#cli-arguments)
  - [Steps](#steps)
  - [Resume Logic](#resume-logic)
  - [Image Sync Tracking](#image-sync-tracking)
  - [Deployment Outputs](#deployment-outputs)
- [Known Limitations](#known-limitations)

---

## Architecture Overview

```
Performance Lab Allocation
│
├── Node 0 → Bastion host
│   ├── Assisted Installer (port 8080)
│   ├── Bastion registry (port 5000 — mirrors OCP + RHOAI operator images)
│   ├── Minio object store (ports 9000/9001)
│   ├── PyPI cache (port 9443)
│   ├── Git cache (ports 9080/9081)
│   └── NFS server (port 2049 — PersistentVolume backing for RHOAI)
│
├── Nodes 1–3 → OpenShift control-plane (masters)
│
└── Nodes 4+ → OpenShift workers (GPU-capable for llm-d)
```

The cluster is deployed **fully disconnected**: all OCP release images and RHOAI operator images are mirrored into the bastion registry before cluster installation begins. After Jetlag finishes, Jenkins installs RHOAI and runs the llm-d test suite.

Default DNS domain for Performance Lab: `rdu3.labs.perfscale.redhat.com`

---

## Prerequisites

Complete the standard [Bastion setup](deploy-mno-performancelab.md#bastion-setup) steps (clone repo, obtain pull-secret).

### Required credentials

| Credential | Used for | How to obtain |
|------------|----------|---------------|
| `pull-secret.txt` | Pulling from `registry.redhat.io` and `quay.io` | Download from [console.redhat.com/openshift/downloads](https://console.redhat.com/openshift/downloads) |
| `GITLAB_TOKEN` env var | Cloning `disconnected-imageset` and `disconnected-s3` repos at deploy time | Internal GitLab token with read access |
| `quay.io/rhoai` access | RHOAI FBC fragment image | Private registry — requires a RHOAI-specific token; contact the RHOAI team |
| AWS credentials | S3 → Minio mirroring (`--s3-mirror-config`) | AWS IAM credentials with S3 read access |

### `credentials.env`

Create this file from the shipped example before running `deploy_rhoai_bm.sh`:

```bash
cp credentials.env.example credentials.env
# Edit credentials.env and fill in the values for your environment
```

`credentials.env` is **gitignored** and must never be committed. `deploy_rhoai_bm.sh` sources it automatically at startup so credentials are never passed as CLI flags or written to shell history.

| Variable | Required for |
|----------|-------------|
| `GITLAB_TOKEN` | Cloning internal GitLab repos (`disconnected-imageset`, `disconnected-s3`) |
| `AWS_ACCESS_KEY_ID` | S3 → Minio mirroring (`--s3-mirror-config`) |
| `AWS_SECRET_ACCESS_KEY` | S3 → Minio mirroring (`--s3-mirror-config`) |
| `AWS_S3_URL` | S3 source endpoint (default: `https://s3.amazonaws.com`) |

---

## Quick Start

```bash
# 1. Clone the repo and place your pull secret
git clone <this-repo> jetlag && cd jetlag
cp /path/to/pull-secret.txt .

# 2. Create the vars file from the RHOAI-specific template
cp ansible/vars/all.rhoai-disconnected-bm.sample.yml ansible/vars/all.yml
# Edit all.yml: set lab_cloud (e.g. cloud02) and worker_node_count

# 3. First-time hardware detection (generates hw-config.yml and nodes-override.json)
python3 scripts/generate-nodes-override.py --init --cloud <cloud-id>

# 4. Deploy
# Credentials are read from credentials.env — no env-var export needed at the shell
./deploy_rhoai_bm.sh <cloud-id> \
  --ocp-version latest-4.19 \
  --ocp-build ga \
  --rhoai-fbc-image quay.io/rhoai/rhoai-fbc-fragment@sha256:<digest>
```

---

## Vars Files

### `ansible/vars/all.yml` (gitignored — create from sample)

Contains infra-level params: lab type, cloud allocation, cluster topology, OCP version, and registry flags. It is **not tracked in git** because it holds environment-specific values.

Create it from the pre-filled RHOAI template:

```bash
cp ansible/vars/all.rhoai-disconnected-bm.sample.yml ansible/vars/all.yml
```

Then fill in the two required fields:

| Field | Description |
|-------|-------------|
| `lab_cloud` | Cloud allocation ID, e.g. `cloud02` |
| `worker_node_count` | Number of bare metal worker nodes, e.g. `3` |

Key settings already pre-filled in the template:

| Setting | Value | Reason |
|---------|-------|--------|
| `lab` | `performancelab` | Target lab |
| `cluster_type` | `mno` | Multi-node OpenShift |
| `setup_bastion_registry` | `true` | Required for disconnected mirroring |
| `use_bastion_registry` | `true` | Routes cluster image pulls through bastion |
| `setup_bastion_rhoai_services` | `true` | Enables Minio, PyPI cache, Git cache |
| `setup_bastion_nfs` | `true` | NFS server on bastion for RHOAI PersistentVolumes (80 × 100 GB exports under `/var/nfs/`); enabled by default since no ODF or local-storage backend is assumed in the disconnected flow |

### `ansible/vars/sync-ocp-release.yml` (gitignored — create manually)

Specifies the OCP release images to mirror to the bastion registry. See [tips-and-vars.md](tips-and-vars.md) for version string formats. The `--ocp-version` and `--ocp-build` flags in `deploy_rhoai_bm.sh` patch this file at runtime.

### `ansible/vars/sync-operator-index.yml` (gitignored — generated at deploy time)

Specifies RHOAI operator and dependency images to mirror. This file is **generated and patched at deploy time** by `deploy_rhoai_bm.sh` when `--rhoai-fbc-image` is provided — do not edit it manually between runs.

The starting template is `ansible/vars/sync-operator-index.sample.yml`, which ships pre-configured with three catalog sources:

| Catalog | `target_catalog` in bastion | `CatalogSource` name | Purpose |
|---------|-----------------------------|----------------------|---------|
| `quay.io/rhoai/rhoai-fbc-fragment@sha256:…` | `rhoai/rhoai-operator-index` | *(per-cluster)* | RHOAI operator |
| `registry.redhat.io/redhat/redhat-operator-index:v4.19` | `redhat/redhat-operator-index` | `redhat-operators` | RHOAI dependencies (ServiceMesh 3.x, Pipelines, NFD, etc.) |
| `registry.redhat.io/redhat/community-operator-index:v4.19` | `redhat/community-operator-index` | `community-operators` | MariaDB |

> **Why `catalog_source_name: redhat-operators`?** The RHOAI operator continuously reconciles its dependency subscriptions (e.g. `servicemeshoperator3`) and hardcodes `source: redhat-operators`. Any deviation reverts on the next reconcile cycle. The CatalogSource must carry that exact name.

> **Why `minVersion: 3.1.0` for `servicemeshoperator3`?** The RHOAI operator sets `startingCSV: servicemeshoperator3.v3.1.0` in its managed subscription. Mirroring only newer versions causes `ConstraintsNotSatisfiable`.

---

## RHOAI Image Automation

Passing `--rhoai-fbc-image` to `deploy_rhoai_bm.sh` triggers the full disconnected-imageset automation pipeline:

1. **Clone `disconnected-imageset`** — authenticated via `GITLAB_TOKEN` env var. Use `--imageset-repo <url>` to override the default internal GitLab URL.
2. **Pin catalog digests** — `catalogs_to_sync[].catalog` fields in `sync-operator-index.yml` are updated with `@sha256:` digests from `disconnected-imageset/resources/ocp-digests.yaml`, ensuring exact reproducibility.
3. **Merge `additional_images`** — images from the following disconnected-imageset directories are merged into `sync-operator-index.yml`:
   - `imagesets/v2/rhoai-ci/` — RHOAI CI infrastructure images
   - `imagesets/v2/rhoai-<version>/` — workbench and framework images for the specific RHOAI release
   - `imagesets/v2/dependent-operators/` — operator bundle images
   - `imagesets/v2/custom-images/` — custom/test images
4. **Set `operator_index_tag`** — derived from `--ocp-version` (e.g. `latest-4.19` → `v4.19`) so the tag filter for CatalogSource generation matches the mirrored content.
5. **Enable `sync_rhoai_registries_conf`** — writes `/etc/containers/registries.conf.d/rhoai.conf` on the bastion so `oc-mirror` resolves `registry.redhat.io/rhoai → quay.io/rhoai`.

---

## Node & Hardware Configuration

Performance Lab allocations do not guarantee consistent node ordering. GPU nodes (intended as workers) may appear early in the QUADS allocation JSON, displacing control-plane nodes. Hardware interventions (NIC firmware updates, re-cabling) can silently change MAC addresses.

Both problems are handled by a script-driven override mechanism.

### `ansible/vars/hw-config.yml`

Auto-generated by `--init`. Declares the hardware profile of the allocation:

```yaml
bmc_user: quads
bmc_password: xxxx

hw_role_hint:
  r740xd: controlplane   # nodes of this model → control-plane
  r750: worker           # nodes of this model → worker

hw_bastion_model: r740xd  # first node of this model → bastion

hw_controlplane_adapter:
  r740xd: NIC.Integrated.1  # auto-detected by --init; update only if cabling changes
  r750: NIC.Slot.3
```

### `scripts/generate-nodes-override.py`

Reads `hw-config.yml`, queries QUADS for the current allocation, then queries each node's iDRAC via Redfish for live MAC addresses. Writes a correctly ordered `nodes-override.json`:

| Position | Role |
|----------|------|
| `nodes[0]` | Bastion |
| `nodes[1–3]` | Control-plane (masters) |
| `nodes[4+]` | Workers |

### First-time setup

```bash
python3 scripts/generate-nodes-override.py --init --cloud <cloud-id>
```

Queries QUADS and Redfish to auto-populate `hw-config.yml`. Review before running `deploy_rhoai_bm.sh`.

### Deployment after hardware changes

```bash
./deploy_rhoai_bm.sh <cloud-id> --refresh-nodes
```

Re-queries Redfish for current MACs and rewrites `nodes-override.json` before the inventory step.

---

## `deploy_rhoai_bm.sh` — End-to-End Entrypoint

`deploy_rhoai_bm.sh` is the single entrypoint for Jenkins/CI automation. It runs all deployment steps in sequence and patches vars files at runtime based on CLI arguments. Helper functions are in `deploy_rhoai_bm_utils.sh` (sourced automatically — do not execute it directly).

### Usage

```bash
./deploy_rhoai_bm.sh <cloud-id> [OPTIONS]

# Minimal (vars already configured):
./deploy_rhoai_bm.sh cloud02

# Full RHOAI disconnected deployment (credentials read from credentials.env):
./deploy_rhoai_bm.sh cloud02 \
  --ocp-version latest-4.19 \
  --ocp-build ga \
  --rhoai-fbc-image quay.io/rhoai/rhoai-fbc-fragment@sha256:<digest> \
  --rhoai-channel beta \
  --rhoai-update-channel beta \
  --gpu-operator nvidia \
  --add-custom-ca-bundles

# Resume after interruption:
./deploy_rhoai_bm.sh cloud02 --resume
```

### CLI Arguments

**Core deployment flags**

| Argument | Description |
|----------|-------------|
| `<cloud-id>` | *(required)* Performance Lab cloud allocation ID, e.g. `cloud02` |
| `--ocp-version VERSION` | OCP version string (e.g. `latest-4.19`, `4.19.1`). Patches `all.yml` and `sync-ocp-release.yml`. Also derives `operator_index_tag` for CatalogSource tag filtering. |
| `--ocp-build BUILD` | OCP build type: `ga`, `dev`, or `ci`. Patches `all.yml`. |
| `--rhoai-fbc-image URL` | RHOAI FBC image digest (e.g. `quay.io/rhoai/rhoai-fbc-fragment@sha256:…`). Triggers the full disconnected-imageset automation: catalog digest pinning, `additional_images` merge, `operator_index_tag` derivation, and `sync_rhoai_registries_conf`. Requires `GITLAB_TOKEN` in `credentials.env`. |
| `--rhoai-channel CHANNEL` | Mirror-side channel (e.g. `stable-3.4`, `beta`). Patches `sync-operator-index.yml` so oc-mirror pulls the correct channel's operator bundles from the FBC catalog into the bastion registry (step 5). **Not** the install-time subscription channel — see `--rhoai-update-channel`. |
| `--rhoai-version VERSION` | RHOAI operator version (e.g. `3.4.0-ea.2`). |
| `--imageset-repo URL` | Override the disconnected-imageset Git URL (default: internal GitLab). |
| `--cluster-name NAME` | OCP cluster name (default: `llmd`). Sets the DNS subdomain and `CLUSTER_APPS_DOMAIN`. Override when multiple clusters share a lab domain. |
| `--nodes-override FILE` | Use a specific `ocpinventory.json`; skips Redfish node refresh. |
| `--refresh-nodes` | Refresh `nodes-override.json` from QUADS + Redfish before deployment. |
| `--resume` | Auto-detect completed steps and skip them. |

**Post-install flags (steps 7a-7d — run after cluster is up)**

| Argument | Description |
|----------|-------------|
| `--gpu-operator nvidia` | *(step 7b)* Install NFD + NVIDIA GPU operator via `ods-ci/gpu_deploy.sh`. Requires the `nvidia-operator` imageset to be mirrored (pass alongside `--rhoai-fbc-image`). |
| `--s3-mirror-config CONFIG[,CONFIG…]` | *(step 7a)* Mirror one or more AWS S3 bucket configs into bastion Minio. CONFIG is the basename of a file under `disconnected-s3/configs/`. Requires `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` in `credentials.env`. |
| `--s3-repo URL` | Override the `disconnected-s3` Git URL (required when `--s3-mirror-config` is set; default repo is internal GitLab). |
| `--rhoai-update-channel CHANNEL` | *(step 7c)* Install-side OLM subscription channel (e.g. `stable-3.4`, `beta`). Passed to `./install-operator.sh rhods-operator <channel>` inside olminstall. Also **triggers** step 7c — omitting this flag skips RHOAI installation entirely even if the mirror is complete. Typically matches `--rhoai-channel`. Use alone with `--resume` to install RHOAI on a cluster whose mirror is already done: `./deploy_rhoai_bm.sh <cloud> --resume --rhoai-update-channel stable-3.4`. |
| `--rhoai-catalog-source NAME` | CatalogSource name for RHOAI subscription (default: `rhoai-catalog-dev`). |
| `--olminstall-repo URL` | Override the `olminstall` Git URL (default: internal GitLab; the repo is public and cloned with `http.sslVerify=false`). |
| `--add-custom-ca-bundles` | *(step 7d)* Append bastion service CA certs (registry, Minio, PyPI cache, Git cache) to `default-dsci` `spec.trustedCABundle.customCABundle`. Requires RHOAI to be installed (step 7c). |

### Steps

| Step | Description |
|------|-------------|
| 1 | Bootstrap Ansible virtual environment |
| 1b | *(opt)* Refresh `nodes-override.json` from QUADS + Redfish (`--refresh-nodes`) |
| 2 | Patch vars files (`all.yml`, `sync-operator-index.yml`), generate Ansible inventory |
| 3 | Setup bastion (registry, DNS, Assisted Installer, Minio/PyPI/Git cache, NFS) |
| 4 | Sync OCP release images to bastion registry |
| 5 | Sync operator index + additional images to bastion registry via `oc-mirror` |
| 6 | Deploy MNO cluster via Assisted Installer |
| post | Apply IDMS/ITMS/CatalogSource manifests from `oc-mirror` working-dir; create `rhoai-catalog-dev` CatalogSource alias; wait for MachineConfigPool rollout; write registry CA manifests and `cluster-info.env` to `/root/mno/` |
| 7a | *(opt)* Mirror AWS S3 buckets → bastion Minio (`--s3-mirror-config`) |
| 7b | *(opt)* Install NFD + NVIDIA GPU operator (`--gpu-operator nvidia`) |
| 7c | *(opt)* Install full RHOAI 3.x stack via olminstall (`--rhoai-update-channel`) |
| 7d | *(opt)* Append bastion CA certs to DSCI `spec.trustedCABundle` (`--add-custom-ca-bundles`) |

### Resume Logic

With `--resume`, each step is skipped if its completion condition is already met:

| Step | Skip condition |
|------|---------------|
| 1 — Bootstrap venv | `.ansible/bin/activate` exists |
| 2 — Prepare vars + inventory | `ansible/inventory/${CLOUD_ID}.local` exists |
| 3 — Setup bastion | Bastion registry responding on port 5000 |
| 4 — Sync OCP release | `.sync-ocp-done` marker present |
| 5 — Sync operator index | `.sync-operators-done` marker present |
| 6 — Deploy cluster | `/root/mno/kubeconfig` exists |
| 7a — S3 mirror | Always re-runs when flag is set (S3 sync is idempotent) |
| 7b — GPU operator | `oc get csv -A` shows a `gpu-operator.*Succeeded` CSV |
| 7c — RHOAI install | `oc get csv -n redhat-ods-operator` shows `rhods-operator.*Succeeded` |
| 7d — CA bundles | `default-dsci` `spec.trustedCABundle.customCABundle` is non-empty |

### Image Sync Tracking

After each sync step, `deploy_rhoai_bm.sh` prints a grouped error summary parsed from the Ansible log:

```
  --- Operator index image sync summary ---
  Error type             Count
  ----------             -----
  manifest-unknown       82
  unauthorized           11
  Full log: ./deploy-logs/cloud02-sync-operators-20250415-120000.log
```

Full logs are written to `./deploy-logs/` with a timestamped filename.

---

### Deployment Outputs

After a successful run the following artifacts are written to `/root/mno/` on the bastion:

| Artifact | Path | Description |
|----------|------|-------------|
| Kubeconfig | `/root/mno/kubeconfig` | Cluster admin kubeconfig. `server:` is patched to `https://<bastion-fqdn>:6443` with `insecure-skip-tls-verify: true` so Jenkins can use it directly without SSH access to the bastion. |
| kubeadmin password | `/root/mno/kubeadmin-password` | Plaintext cluster admin password. |
| Cluster info | `/root/mno/cluster-info.env` | Machine-readable env file — stable interface for Jenkins and other consumers. |
| Registry CA ConfigMap | `/root/mno/registry-ca-configmap.yaml` | OCP manifest to trust the bastion self-signed registry CA. Apply with `oc apply -f`. |
| Image config patch | `/root/mno/image-config-patch.yaml` | Patch for `image.config.openshift.io/cluster` that references the CA ConfigMap. Apply with `oc patch --patch-file`. |

**`cluster-info.env` schema:**

```bash
CLUSTER_API_URL=https://<bastion-fqdn>:6443         # externally reachable API endpoint (via HAProxy)
CLUSTER_APPS_DOMAIN=apps.<cluster>.<base_dns>        # wildcard app route domain
BASTION_FQDN=<bastion-fqdn>                         # bastion hostname (publicly resolvable)
KUBECONFIG_PATH=/root/mno/kubeconfig                 # path to cluster admin kubeconfig (server: patched to bastion FQDN)
KUBEADMIN_PASSWORD_PATH=/root/mno/kubeadmin-password
SQUID_HTTP_PROXY=http://<bastion-fqdn>:3128          # Squid forward proxy for app-route resolution
SQUID_HTTPS_PROXY=http://<bastion-fqdn>:3128         # same proxy for HTTPS CONNECT tunneling
RHOAI_FBC_IMAGE=<image@digest>                       # FBC image used at deploy time (empty if not provided)
```

External consumers read `CLUSTER_APPS_DOMAIN` to construct app route URLs. `CLUSTER_API_URL` is the externally reachable API endpoint via HAProxy — no direct cluster network access is required. Jenkins sets `HTTPS_PROXY=${SQUID_HTTPS_PROXY}` so pod agents can resolve `*.apps.*` routes through the bastion's local dnsmasq.

---

## Known Limitations

1. **`servicemeshoperator3.v3.1.0` must be in the mirrored catalog** — RHOAI operator hardcodes `startingCSV: servicemeshoperator3.v3.1.0` in its managed subscription and reverts any manual changes. The `sync-operator-index.sample.yml` includes `minVersion: 3.1.0` to ensure the v3.1.0 bundle is mirrored. If GatewayConfig is not ready after install, confirm `servicemeshoperator3` CSV is `Succeeded` in the `openshift-operators` namespace.

2. **Node ordering in allocation** — GPU nodes intended as workers may appear early in the QUADS allocation JSON. Use `--refresh-nodes` or the manual override flow described in [Node & Hardware Configuration](#node--hardware-configuration).
