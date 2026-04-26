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
- [deploy.sh — End-to-End Entrypoint](#deploysh--end-to-end-entrypoint)
  - [Usage](#usage)
  - [CLI Arguments](#cli-arguments)
  - [Steps](#steps)
  - [Resume Logic](#resume-logic)
  - [Image Sync Tracking](#image-sync-tracking)
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
│   └── Git cache (ports 9080/9081)
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
| `GITLAB_TOKEN` env var | Cloning `disconnected-imageset` repo at deploy time | Internal GitLab token with read access |
| `quay.io/rhoai` access | RHOAI FBC fragment image | Private registry — requires a RHOAI-specific token; contact the RHOAI team |

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
export GITLAB_TOKEN=<your-token>
./deploy.sh <cloud-id> \
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

### `ansible/vars/sync-ocp-release.yml` (gitignored — create manually)

Specifies the OCP release images to mirror to the bastion registry. See [tips-and-vars.md](tips-and-vars.md) for version string formats. The `--ocp-version` and `--ocp-build` flags in `deploy.sh` patch this file at runtime.

### `ansible/vars/sync-operator-index.yml` (gitignored — generated at deploy time)

Specifies RHOAI operator and dependency images to mirror. This file is **generated and patched at deploy time** by `deploy.sh` when `--rhoai-fbc-image` is provided — do not edit it manually between runs.

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

Passing `--rhoai-fbc-image` to `deploy.sh` triggers the full disconnected-imageset automation pipeline:

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

Queries QUADS and Redfish to auto-populate `hw-config.yml`. Review before running `deploy.sh`.

### Deployment after hardware changes

```bash
./deploy.sh <cloud-id> --refresh-nodes
```

Re-queries Redfish for current MACs and rewrites `nodes-override.json` before the inventory step.

---

## `deploy.sh` — End-to-End Entrypoint

`deploy.sh` is the single entrypoint for Jenkins/CI automation. It runs all six deployment steps in sequence and patches vars files at runtime based on CLI arguments.

### Usage

```bash
./deploy.sh <cloud-id> [OPTIONS]

# Minimal (vars already configured):
./deploy.sh cloud02

# Full RHOAI disconnected deployment:
export GITLAB_TOKEN=<token>
./deploy.sh cloud02 \
  --ocp-version latest-4.19 \
  --ocp-build ga \
  --rhoai-fbc-image quay.io/rhoai/rhoai-fbc-fragment@sha256:<digest>

# Resume after interruption:
./deploy.sh cloud02 --resume
```

### CLI Arguments

| Argument | Description |
|----------|-------------|
| `<cloud-id>` | *(required)* Performance Lab cloud allocation ID, e.g. `cloud02` |
| `--ocp-version VERSION` | OCP version string (e.g. `latest-4.19`, `4.19.1`). Patches `all.yml` and `sync-ocp-release.yml`. Also derives `operator_index_tag` for CatalogSource tag filtering. |
| `--ocp-build BUILD` | OCP build type: `ga`, `dev`, or `ci`. Patches `all.yml`. |
| `--rhoai-fbc-image URL` | RHOAI FBC image digest (e.g. `quay.io/rhoai/rhoai-fbc-fragment@sha256:…`). Triggers the full disconnected-imageset automation: catalog digest pinning, `additional_images` merge, `operator_index_tag` derivation, and `sync_rhoai_registries_conf`. Requires `GITLAB_TOKEN` env var. |
| `--rhoai-channel CHANNEL` | RHOAI operator channel (e.g. `beta`). Use alongside `--rhoai-fbc-image` for EA/pre-GA releases where the channel cannot be auto-derived. |
| `--rhoai-version VERSION` | RHOAI operator version (e.g. `3.4.0-ea.2`). |
| `--imageset-repo URL` | Override the disconnected-imageset Git URL (default: internal GitLab). |
| `--nodes-override FILE` | Use a specific `ocpinventory.json`; skips Redfish node refresh. |
| `--refresh-nodes` | Refresh `nodes-override.json` from QUADS + Redfish before deployment. |
| `--resume` | Auto-detect completed steps and skip them. |

### Steps

| Step | Description |
|------|-------------|
| 1 | Bootstrap Ansible virtual environment |
| 2 | Patch vars files (`all.yml`, `sync-operator-index.yml`), generate Ansible inventory |
| 3 | Setup bastion (registry, DNS, Assisted Installer, Minio/PyPI/Git cache if enabled) |
| 4 | Sync OCP release images to bastion registry |
| 5 | Sync operator index + additional images to bastion registry via `oc-mirror` |
| 6 | Deploy MNO cluster via Assisted Installer |
| post | Apply IDMS/ITMS/CatalogSource manifests from `oc-mirror` working-dir; wait for MachineConfigPool rollout; write registry CA manifests to `/root/mno/` |

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

### Image Sync Tracking

After each sync step, `deploy.sh` prints a grouped error summary parsed from the Ansible log:

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

## Known Limitations

1. **`servicemeshoperator3.v3.1.0` must be in the mirrored catalog** — RHOAI operator hardcodes `startingCSV: servicemeshoperator3.v3.1.0` in its managed subscription and reverts any manual changes. The `sync-operator-index.sample.yml` includes `minVersion: 3.1.0` to ensure the v3.1.0 bundle is mirrored. If GatewayConfig is not ready after install, confirm `servicemeshoperator3` CSV is `Succeeded` in the `openshift-operators` namespace.

2. **Node ordering in allocation** — GPU nodes intended as workers may appear early in the QUADS allocation JSON. Use `--refresh-nodes` or the manual override flow described in [Node & Hardware Configuration](#node--hardware-configuration).
