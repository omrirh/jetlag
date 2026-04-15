# Disconnected RHOAI / llm-d Deployment on Performance Lab

This document describes how this Jetlag fork is adapted for deploying a **disconnected bare-metal OpenShift cluster on Performance Lab** to run **Red Hat OpenShift AI (RHOAI) with llm-d 3.4** as part of the OpenShift AI test suite.

> **Before reading this document**, familiarize yourself with the standard Performance Lab MNO deployment guide:
> [docs/deploy-mno-performancelab.md](deploy-mno-performancelab.md)
>
> This document builds on that guide and only covers what is **specific to this use case**.

---

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Prerequisites](#prerequisites)
  - [Required Auth Tokens](#required-auth-tokens)
- [Pre-configured Vars Files](#pre-configured-vars-files)
- [Node Ordering Problem & Override Mechanism](#node-ordering-problem--override-mechanism)
- [deploy.sh — End-to-End Entrypoint](#deploysh--end-to-end-entrypoint)
  - [Usage](#usage)
  - [CLI Arguments](#cli-arguments)
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
│   ├── Bastion registry (mirrors: OCP + RHOAI operator images)
│   └── CoreDNS / dnsmasq
│
├── Nodes 1–3 → OpenShift control-plane (masters)
│
└── Nodes 4+ → OpenShift workers (GPU-capable for llm-d)
```

The cluster is deployed **fully disconnected**: all OCP release images and RHOAI operator images are mirrored into the bastion registry before cluster installation begins. After Jetlag finishes, our Jenkins automation installs RHOAI and runs the llm-d test suite.

Default DNS domain for Performance Lab: `rdu3.labs.perfscale.redhat.com`

---

## Prerequisites

Complete the standard [Bastion setup](deploy-mno-performancelab.md#bastion-setup) steps (clone repo, pull-secret, bootstrap venv).

### Required Auth Tokens

The disconnected mirroring steps pull from several registries. Your `pull-secret.txt` must include valid credentials for each. See [deploy-mno-performancelab.md — Bastion setup](deploy-mno-performancelab.md#bastion-setup) for how to download your pull secret.

| Registry | Used for | How to obtain |
|----------|----------|---------------|
| `registry.redhat.io` | OCP release images, RHOAI dependency operators | Red Hat account token from [console.redhat.com/openshift/downloads](https://console.redhat.com/openshift/downloads) |
| `quay.io` | Additional images (MinIO, test images, etc.) | Quay.io account token, same pull-secret download |
| `quay.io/rhoai` | RHOAI FBC fragment catalog image | Private registry — requires a separate RHOAI-specific token; contact the RHOAI team |

---

## Pre-configured Vars Files

Three vars files ship pre-configured for this use case. They are located in `ansible/vars/` and are consumed directly by Jetlag's Ansible roles.

### `ansible/vars/all.yml`

Defines infra-level params: lab type, cluster topology, OCP version, and disconnected registry settings.

Key settings already configured for this use case:
- `lab: performancelab`
- `cluster_type: mno`
- `worker_node_count: 2`
- `setup_bastion_registry: true` / `use_bastion_registry: true` (disconnected mode)

See [all.yml](../ansible/vars/all.yml) and the [standard guide](deploy-mno-performancelab.md#configure-ansible-vars-in-allyml) for full variable reference.

### `ansible/vars/sync-ocp-release.yml`

Specifies the OCP release images to mirror to the bastion registry. Controlled via `ocp_build` and `ocp_version`.

See [tips-and-vars.md — OCP Version](tips-and-vars.md) for version string formats.

### `ansible/vars/sync-operator-index.yml`

Specifies RHOAI operator and dependency images to mirror. This file contains three catalog sources:

| Catalog | Purpose |
|---------|---------|
| `quay.io/rhoai/rhoai-fbc-fragment@sha256:…` | RHOAI operator (FBC fragment, versioned by digest) |
| `registry.redhat.io/redhat/redhat-operator-index:v4.20` | RHOAI dependencies (Pipelines, ServiceMesh, NFD, etc.) |
| `registry.redhat.io/redhat/community-operator-index:v4.20` | MariaDB community operator |

**Template customization:** `ansible/roles/sync-operator-index/templates/imagesetconf.yml.j2` has been modified to:
- Support per-catalog `target_catalog` destination (allows RHOAI FBC to land in its own index namespace)
- Make `minVersion`/`maxVersion` optional per channel (standard Jetlag requires them)

---

## Node Ordering Problem & Override Mechanism

Performance Lab allocations do not guarantee node ordering. The bastion is always `nodes[0]` in the allocation JSON, but GPU nodes (intended as workers) may appear early in the list, displacing control-plane nodes.

**Jetlag's built-in override mechanism** handles this via the `ocp_inventory_override` variable in `all.yml`:

```yaml
# ansible/vars/all.yml
ocp_inventory_override: /path/to/custom-ocpinventory.json
```

When set, Jetlag reads nodes from this file instead of the QUADS API. Node assignment is positional:

| Position | Role |
|----------|------|
| `nodes[0]` | Bastion |
| `nodes[1–3]` | Control-plane (masters) |
| `nodes[4+]` | Workers |

**How to create a custom inventory JSON:**

1. Retrieve the default inventory from QUADS (Jetlag fetches this automatically; you can inspect it at `http://quads2.rdu3.labs.perfscale.redhat.com/api/v3/cloud/<cloud-id>/`) or use `--nodes-override` with `deploy.sh` (see below) to point to a pre-built JSON.
2. Reorder the `nodes` array so GPU/worker machines appear after the three control-plane candidates.
3. Save the file locally (e.g., `nodes-override.json`) and pass it via CLI or set `ocp_inventory_override` directly.

See [tips-and-vars.md — Override lab ocpinventory json file](tips-and-vars.md) for full details.

---

## `deploy.sh` — End-to-End Entrypoint

`deploy.sh` is the single entrypoint for Jenkins/TestOps CI automation. It runs all six deployment steps in sequence and patches vars files at runtime based on CLI arguments.

### Usage

```bash
./deploy.sh <cloud-id> [OPTIONS]

# Examples:
./deploy.sh cloud02
./deploy.sh cloud02 --ocp-version 4.20.1 --rhoai-version 3.4.0-ea.2
./deploy.sh cloud02 --nodes-override /path/to/nodes-override.json --resume
```

### CLI Arguments

| Argument | Default | Description |
|----------|---------|-------------|
| `<cloud-id>` | *(required)* | Performance Lab cloud allocation ID (e.g. `cloud02`) |
| `--ocp-version VERSION` | value in `all.yml` | Override OCP version in both `all.yml` and `sync-ocp-release.yml` |
| `--ocp-build BUILD` | value in `all.yml` | Override OCP build type (`ga`, `dev`, or `ci`) |
| `--rhoai-catalog URL` | value in `sync-operator-index.yml` | RHOAI FBC fragment catalog URL (digest-pinned) |
| `--rhoai-fbc-image URL` | *(unset)* | RHOAI FBC image to mirror as a standalone additional image |
| `--rhoai-version VERSION` | value in `sync-operator-index.yml` | RHOAI operator version (e.g. `3.4.0-ea.2`) |
| `--rhoai-channel CHANNEL` | value in `sync-operator-index.yml` | RHOAI operator channel (e.g. `beta`) |
| `--nodes-override FILE` | *(unset)* | Path to custom `ocpinventory.json`; sets `ocp_inventory_override` in `all.yml` |
| `--resume` | *(off)* | Auto-detect completed steps and skip them |

### Resume Logic

With `--resume`, `deploy.sh` checks markers before each step:

| Step | Skip Condition |
|------|---------------|
| 1 — Bootstrap venv | `.ansible/bin/activate` exists |
| 2 — Prepare vars + generate inventory | `ansible/inventory/${CLOUD_ID}.local` exists |
| 3 — Setup bastion | Bastion registry responding on port 5000 |
| 4 — Sync OCP release | `.sync-ocp-done` marker file present |
| 5 — Sync operator index | `.sync-operators-done` marker file present |
| 6 — Deploy cluster | `/root/mno/kubeconfig` exists |

### Image Sync Tracking

After each sync step (`4` and `5`), `deploy.sh` prints a summary of image pull results parsed from the captured Ansible log. Errors are grouped by type:

```
  --- Operator index image sync summary ---
  Error type             Count
  ----------             -----
  manifest-unknown       82
  unauthorized           11
  bundle skipped         1
  Full log: ./deploy-logs/cloud02-sync-operators-20250415-120000.log
```

Full logs for each run are saved under `./deploy-logs/` with a timestamped filename. Different failure categories reflect different root causes (e.g., `manifest-unknown` typically means the image digest or tag doesn't exist in the source registry; `unauthorized` indicates missing or expired auth tokens for that registry). Inspect the full log to see which specific images failed.

---

## Known Limitations

1. **`odh-*` image pull failures**: Some `odh-*` pattern images in `sync-operator-index.yml` currently fail to pull. Root cause is under investigation. These failures cause `sync-operator-index.yml` to error out unless the problematic images are removed from `additional_images`.

2. **Node ordering in allocation**: GPU nodes intended as workers may appear early in the QUADS allocation JSON, causing them to be assigned as control-plane nodes. Mitigate via `--nodes-override` with a pre-reordered `ocpinventory.json` (see [above](#node-ordering-problem--override-mechanism)).
