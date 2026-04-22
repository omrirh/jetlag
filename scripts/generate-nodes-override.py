#!/usr/bin/env python3
"""
Generate or refresh nodes-override.json for Jetlag Performance Lab deployments.

Two modes:

  --init   Bootstrap hw-config.yml from QUADS allocation + Redfish discovery.
           Run once when the hardware profile of the allocation changes (new
           models, re-cabling). Produces a hw-config.yml you can review and
           commit.

  (none)   Refresh nodes-override.json using hw-config.yml + live Redfish
           MACs. Run automatically before every deployment via deploy.sh to
           pick up any MAC changes from firmware updates or NIC swaps.

Examples:
  # First-time setup for cloud02
  python3 scripts/generate-nodes-override.py --init --cloud cloud02

  # Refresh before deployment (called by deploy.sh)
  python3 scripts/generate-nodes-override.py --cloud cloud02
"""

import argparse
import base64
import json
import ssl
import sys
import urllib.request
import urllib.error
from pathlib import Path

try:
    import yaml
except ImportError:
    print(
        "Error: PyYAML not found. Activate the Jetlag venv first:\n"
        "  source .ansible/bin/activate",
        file=sys.stderr,
    )
    sys.exit(1)

SCRIPT_DIR = Path(__file__).parent.resolve()
REPO_ROOT = SCRIPT_DIR.parent
LAB_VARS = REPO_ROOT / "ansible" / "vars" / "lab.yml"

# Role defaults for known Performance Lab hardware models.
# Used by --init to pre-populate hw_role_hint without manual lookup.
_WORKER_MODELS = {"r750", "r760", "xe8640", "xe9680", "r7525", "r7625", "r6526"}
_CP_MODELS = {"r630", "r640", "r650", "r660", "r730xd", "r740xd", "r930", "fc640", "r7425"}


# ---------------------------------------------------------------------------
# Redfish helpers
# ---------------------------------------------------------------------------

def _ssl_ctx():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def redfish_get(bmc_addr, path, user, password, timeout=15):
    url = f"https://{bmc_addr}{path}"
    req = urllib.request.Request(url)
    token = base64.b64encode(f"{user}:{password}".encode()).decode()
    req.add_header("Authorization", f"Basic {token}")
    req.add_header("Accept", "application/json")
    try:
        with urllib.request.urlopen(req, context=_ssl_ctx(), timeout=timeout) as resp:
            return json.loads(resp.read())
    except Exception as exc:
        raise RuntimeError(f"Redfish GET {url}: {exc}") from exc


def get_node_model(bmc_addr, user, password):
    """Return lowercase hardware model, e.g. 'r750' from 'PowerEdge R750'."""
    data = redfish_get(bmc_addr, "/redfish/v1/Systems/System.Embedded.1", user, password)
    raw = data.get("Model", "").strip()
    return raw.split()[-1].lower() if raw else "unknown"


def get_adapter_ports(bmc_addr, adapter_id, user, password):
    """Return list of (port_id, [macs], speed_mbps) for one adapter."""
    ports_data = redfish_get(
        bmc_addr,
        f"/redfish/v1/Chassis/System.Embedded.1/NetworkAdapters/{adapter_id}/NetworkPorts",
        user,
        password,
    )
    result = []
    for member in ports_data.get("Members", []):
        port_path = member["@odata.id"]
        port_id = port_path.split("/")[-1]
        try:
            port_data = redfish_get(bmc_addr, port_path, user, password)
            macs = port_data.get("AssociatedNetworkAddresses") or []
            speed = port_data.get("CurrentLinkSpeedMbps") or 0
        except RuntimeError:
            macs, speed = [], 0
        if macs:
            result.append((port_id, macs, int(speed)))
    return result


def list_adapters(bmc_addr, user, password):
    """Return list of adapter IDs, excluding iDRAC internal adapters."""
    data = redfish_get(
        bmc_addr,
        "/redfish/v1/Chassis/System.Embedded.1/NetworkAdapters",
        user,
        password,
    )
    return [
        m["@odata.id"].split("/")[-1]
        for m in data.get("Members", [])
        if "iDRAC" not in m["@odata.id"]
    ]


def build_mac_list(bmc_addr, controlplane_adapter_id, user, password):
    """
    Return ordered MAC list: controlplane adapter ports first (→ mac[0], mac[1]),
    then all remaining adapter ports. Falls back to empty list on error.
    """
    try:
        all_adapter_ids = list_adapters(bmc_addr, user, password)
    except RuntimeError as exc:
        raise RuntimeError(f"Cannot list adapters on {bmc_addr}: {exc}") from exc

    macs = []
    # Controlplane adapter first
    if controlplane_adapter_id in all_adapter_ids:
        for _, port_macs, _ in get_adapter_ports(bmc_addr, controlplane_adapter_id, user, password):
            macs.extend(port_macs)
    # Remaining adapters in their Redfish order
    for adapter_id in all_adapter_ids:
        if adapter_id == controlplane_adapter_id:
            continue
        try:
            for _, port_macs, _ in get_adapter_ports(bmc_addr, adapter_id, user, password):
                macs.extend(port_macs)
        except RuntimeError:
            pass
    return macs


def suggest_controlplane_adapter(bmc_addr, user, password):
    """
    Suggest the controlplane adapter by selecting the highest-speed
    non-iDRAC adapter. Returns (adapter_id, max_speed_mbps).
    """
    best_adapter, best_speed = None, 0
    for adapter_id in list_adapters(bmc_addr, user, password):
        try:
            for _, _, speed in get_adapter_ports(bmc_addr, adapter_id, user, password):
                if speed > best_speed:
                    best_speed = speed
                    best_adapter = adapter_id
        except RuntimeError:
            pass
    return best_adapter, best_speed


# ---------------------------------------------------------------------------
# QUADS
# ---------------------------------------------------------------------------

def fetch_quads_inventory(quads_url, cloud_id):
    url = f"{quads_url.rstrip('/')}/instack/{cloud_id}_ocpinventory.json"
    try:
        with urllib.request.urlopen(url, timeout=15) as resp:
            return json.loads(resp.read())
    except Exception as exc:
        raise RuntimeError(f"Failed to fetch QUADS inventory from {url}: {exc}") from exc


# ---------------------------------------------------------------------------
# --init: bootstrap hw-config.yml
# ---------------------------------------------------------------------------

def cmd_init(args):
    hw_config_path = Path(args.hw_config)
    if hw_config_path.exists() and not args.force:
        print(
            f"Error: {hw_config_path} already exists. Use --force to overwrite.",
            file=sys.stderr,
        )
        sys.exit(1)

    print(f"==> Fetching allocation from QUADS ({args.quads_url}, {args.cloud}) ...")
    inventory = fetch_quads_inventory(args.quads_url, args.cloud)
    nodes = inventory["nodes"]
    print(f"    Found {len(nodes)} nodes")

    # Discover model for each node; track one representative BMC per model
    models_seen = {}   # model → (bmc_addr, user, password)
    node_models = []   # [(node, model)]
    for i, node in enumerate(nodes):
        bmc = node["pm_addr"]
        user = node.get("pm_user", args.bmc_user)
        pwd = node.get("pm_password", args.bmc_password)
        print(f"    [{i+1}/{len(nodes)}] {bmc} ...", end=" ", flush=True)
        try:
            model = get_node_model(bmc, user, pwd)
        except RuntimeError as exc:
            print(f"WARNING: {exc}")
            model = "unknown"
        print(model)
        node_models.append((node, model))
        if model not in models_seen:
            models_seen[model] = (bmc, user, pwd)

    # Role hints — derive from known model lists
    hw_role_hint = {}
    for model in models_seen:
        if model in _WORKER_MODELS:
            hw_role_hint[model] = "worker"
        elif model in _CP_MODELS:
            hw_role_hint[model] = "controlplane"
        else:
            hw_role_hint[model] = "worker"
            print(f"    NOTE: unknown model '{model}' — defaulting role to 'worker'. Review hw-config.yml.")

    # Controlplane adapter — highest-speed non-iDRAC adapter per model
    hw_controlplane_adapter = {}
    for model, (bmc, user, pwd) in models_seen.items():
        if model == "unknown":
            continue
        print(f"    Discovering adapters on {bmc} (model: {model}) ...", end=" ", flush=True)
        try:
            adapter_id, speed = suggest_controlplane_adapter(bmc, user, pwd)
            if adapter_id:
                hw_controlplane_adapter[model] = adapter_id
                print(f"{adapter_id} @ {speed} Mbps")
            else:
                hw_controlplane_adapter[model] = "NIC.Integrated.1"
                print("no adapter found — defaulting to NIC.Integrated.1")
        except RuntimeError as exc:
            hw_controlplane_adapter[model] = "NIC.Integrated.1"
            print(f"WARNING: {exc} — defaulting to NIC.Integrated.1")

    # Use quads credentials from first node as defaults in the file
    first_node = nodes[0]
    bmc_user_out = first_node.get("pm_user", args.bmc_user)
    bmc_pass_out = first_node.get("pm_password", args.bmc_password)

    lines = [
        "# Hardware configuration for Jetlag Performance Lab deployments.",
        f"# Generated by: scripts/generate-nodes-override.py --init --cloud {args.cloud}",
        "#",
        "# hw_role_hint",
        "#   Maps hardware model → cluster role.",
        "#   controlplane: assigned to OCP control-plane (nodes[1-3] in nodes-override.json)",
        "#   worker:       assigned to OCP workers (nodes[4+])",
        "#   bastion is always nodes[0] from the QUADS allocation.",
        "#   Update when new hardware models are added to the allocation.",
        "#",
        "# hw_controlplane_adapter",
        "#   Redfish NetworkAdapter ID for the NIC physically cabled to",
        "#   the controlplane VLAN (default: 198.18.0.0/16).",
        "#   Update when cabling changes.",
        "",
        f"bmc_user: {bmc_user_out}",
        f"bmc_password: {bmc_pass_out}",
        "",
        "hw_role_hint:",
    ]
    for model, role in sorted(hw_role_hint.items()):
        lines.append(f"  {model}: {role}")
    # Bastion model: most frequent controlplane-role model (typically the shared model)
    cp_model_counts: dict[str, int] = {}
    for _, model in node_models[1:]:  # skip nodes[0] which is quads-assigned bastion
        if hw_role_hint.get(model) == "controlplane":
            cp_model_counts[model] = cp_model_counts.get(model, 0) + 1
    hw_bastion_model = max(cp_model_counts, key=cp_model_counts.get) if cp_model_counts else None

    lines += [
        "",
        "# hw_bastion_model: hardware model of the bastion node.",
        "# The first node of this model in the QUADS allocation becomes the bastion.",
        "# Remaining nodes of this model become controlplane.",
    ]
    if hw_bastion_model:
        lines.append(f"hw_bastion_model: {hw_bastion_model}")
    else:
        lines.append("# hw_bastion_model:  # TODO: set to the bastion hardware model")

    lines += ["", "hw_controlplane_adapter:"]
    for model, adapter in sorted(hw_controlplane_adapter.items()):
        lines.append(f"  {model}: {adapter}")
    lines.append("")

    hw_config_path.parent.mkdir(parents=True, exist_ok=True)
    hw_config_path.write_text("\n".join(lines))
    print(f"\n==> Written: {hw_config_path}")
    print("    Review hw_role_hint and hw_controlplane_adapter before deploying.")


# ---------------------------------------------------------------------------
# Default mode: refresh nodes-override.json
# ---------------------------------------------------------------------------

def cmd_refresh(args):
    hw_config_path = Path(args.hw_config)
    if not hw_config_path.exists():
        print(
            f"Error: {hw_config_path} not found.\n"
            f"Run --init first:  python3 scripts/generate-nodes-override.py --init --cloud {args.cloud}",
            file=sys.stderr,
        )
        sys.exit(1)

    with open(hw_config_path) as f:
        hw_cfg = yaml.safe_load(f)

    bmc_user = hw_cfg.get("bmc_user", args.bmc_user)
    bmc_password = hw_cfg.get("bmc_password", args.bmc_password)
    hw_role_hint = hw_cfg.get("hw_role_hint", {})
    hw_cp_adapter = hw_cfg.get("hw_controlplane_adapter", {})

    print(f"==> Fetching allocation from QUADS ({args.quads_url}, {args.cloud}) ...")
    inventory = fetch_quads_inventory(args.quads_url, args.cloud)
    nodes = inventory["nodes"]
    print(f"    Found {len(nodes)} nodes")

    enriched = []
    for i, node in enumerate(nodes):
        bmc = node["pm_addr"]
        user = node.get("pm_user", bmc_user)
        pwd = node.get("pm_password", bmc_password)
        print(f"    [{i+1}/{len(nodes)}] {bmc} ...", end=" ", flush=True)

        try:
            model = get_node_model(bmc, user, pwd)
        except RuntimeError as exc:
            print(f"WARNING model query failed: {exc}")
            model = "unknown"

        role = hw_role_hint.get(model, "worker")
        cp_adapter = hw_cp_adapter.get(model)

        try:
            if cp_adapter:
                macs = build_mac_list(bmc, cp_adapter, user, pwd)
            else:
                macs = node.get("mac", [])
                print(f"WARNING no hw_controlplane_adapter for '{model}' — using QUADS MACs", end=" ")
        except RuntimeError as exc:
            print(f"WARNING MAC query failed: {exc} — using QUADS MACs", end=" ")
            macs = node.get("mac", [])

        mac0 = macs[0] if macs else "N/A"
        print(f"model={model} role={role} mac[0]={mac0}")
        enriched.append({"node": node, "model": model, "role": role, "macs": macs})

    # Sort: bastion → controlplane → worker
    # hw_bastion_model identifies which model's first node is the bastion.
    # Without it, quads nodes[0] is used (correct only if quads ordering is stable).
    hw_bastion_model = hw_cfg.get("hw_bastion_model")
    if hw_bastion_model:
        bastion_idx = next(
            (i for i, e in enumerate(enriched) if e["model"] == hw_bastion_model), 0
        )
    else:
        bastion_idx = 0
    bastion = enriched[bastion_idx]
    rest = [e for i, e in enumerate(enriched) if i != bastion_idx]
    cp_nodes = [n for n in rest if n["role"] == "controlplane"]
    worker_nodes = [n for n in rest if n["role"] != "controlplane"]
    ordered = [bastion] + cp_nodes + worker_nodes

    output_nodes = []
    for e in ordered:
        orig = e["node"]
        output_nodes.append({
            "arch": orig.get("arch", "x86_64"),
            "cpu": orig.get("cpu", "2"),
            "disk": orig.get("disk", "20"),
            "mac": e["macs"],
            "memory": orig.get("memory", "1024"),
            "name": orig["name"],
            "pm_addr": orig["pm_addr"],
            "pm_password": orig["pm_password"],
            "pm_type": orig.get("pm_type", "pxe_ipmitool"),
            "pm_user": orig["pm_user"],
        })

    out_path = Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps({"nodes": output_nodes}, indent=2) + "\n")

    print(f"\n==> Written: {out_path}")
    print(f"    bastion:       {ordered[0]['node']['name'].split('.')[0]}")
    print(f"    controlplane:  {[e['node']['name'].split('.')[0] for e in cp_nodes]}")
    print(f"    workers:       {[e['node']['name'].split('.')[0] for e in worker_nodes]}")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def _default_quads_url():
    if LAB_VARS.exists():
        with open(LAB_VARS) as f:
            data = yaml.safe_load(f)
        quads_host = data.get("labs", {}).get("performancelab", {}).get("quads", "")
        if quads_host:
            return f"http://{quads_host}"
    return "http://quads2.rdu3.labs.perfscale.redhat.com"


def main():
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--cloud", required=True, help="Lab cloud allocation ID (e.g. cloud02)")
    parser.add_argument("--init", action="store_true",
                        help="Bootstrap hw-config.yml from QUADS + Redfish discovery")
    parser.add_argument("--force", action="store_true",
                        help="Overwrite existing hw-config.yml (only with --init)")
    parser.add_argument(
        "--hw-config",
        default=str(REPO_ROOT / "ansible" / "vars" / "hw-config.yml"),
        help="Path to hw-config.yml (default: ansible/vars/hw-config.yml)",
    )
    parser.add_argument(
        "--output",
        default=str(REPO_ROOT / "nodes-override.json"),
        help="Path to write nodes-override.json (default: nodes-override.json)",
    )
    parser.add_argument(
        "--quads-url",
        default=_default_quads_url(),
        help="QUADS base URL (default: read from ansible/vars/lab.yml)",
    )
    parser.add_argument("--bmc-user", default="quads", help="Fallback BMC username")
    parser.add_argument("--bmc-password", default="", help="Fallback BMC password")

    args = parser.parse_args()

    if args.init:
        cmd_init(args)
    else:
        cmd_refresh(args)


if __name__ == "__main__":
    main()
