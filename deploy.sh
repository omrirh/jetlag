#!/usr/bin/env bash
# deploy.sh - End-to-end disconnected MNO deployment on Performance Lab bare metal
#
# Usage: ./deploy.sh <cloud-id> [OPTIONS]
#   e.g. ./deploy.sh cloud02
#        ./deploy.sh cloud02 --ocp-version 4.20.1 --rhoai-version 3.4.0-ea.2
#        ./deploy.sh cloud02 --nodes-override /path/to/nodes.json --resume
#
# Assumes:
#   - ansible/vars/all.yml is configured (lab, cluster_type, registry flags, etc.)
#   - ansible/vars/sync-ocp-release.yml is configured
#   - ansible/vars/sync-operator-index.yml is configured
#   - pull-secret.txt is present at the repo root
#   - Script is run from the repo root on the bastion machine

set -euo pipefail

################################################################################
# Defaults
################################################################################
CLOUD_ID=""
OCP_VERSION=""
OCP_BUILD=""
RHOAI_CATALOG=""
RHOAI_FBC_IMAGE=""
RHOAI_VERSION=""
RHOAI_CHANNEL=""
NODES_OVERRIDE=""
RESUME=false

ALL_VARS="ansible/vars/all.yml"
SYNC_OCP_VARS="ansible/vars/sync-ocp-release.yml"
SYNC_OP_VARS="ansible/vars/sync-operator-index.yml"

MARKER_SYNC_OCP=".sync-ocp-done"
MARKER_SYNC_OP=".sync-operators-done"

LOGS_DIR="deploy-logs"

################################################################################
# Helpers
################################################################################
usage() {
	cat <<EOF
Usage: $0 <cloud-id> [OPTIONS]

Arguments:
  <cloud-id>                Performance Lab cloud allocation ID (e.g. cloud02)

Options:
  --ocp-version VERSION     Override OCP version (e.g. 4.20.1, latest-4.20)
  --ocp-build BUILD         Override OCP build type (ga, dev, ci)
  --rhoai-catalog URL       RHOAI FBC fragment catalog URL (digest-pinned)
  --rhoai-fbc-image URL     RHOAI FBC image to mirror as an additional image
  --rhoai-version VERSION   RHOAI operator version (e.g. 3.4.0-ea.2)
  --rhoai-channel CHANNEL   RHOAI operator channel (e.g. beta)
  --nodes-override FILE     Path to custom ocpinventory.json for node role assignment
  --resume                  Auto-detect completed steps and skip them
  -h, --help                Show this help

Steps:
  1  Bootstrap ansible virtual environment
  2  Prepare vars and generate inventory for <cloud-id>
  3  Setup bastion (registry, DNS, Assisted Installer)
  4  Sync OCP release images to bastion registry
  5  Sync operator index + additional images to bastion registry
  6  Deploy MNO cluster

Logs from sync steps are written to: ./${LOGS_DIR}/

EOF
	exit 1
}

die() { echo "Error: $*" >&2; exit 1; }

################################################################################
# Resume: check if a step is already done
################################################################################
check_step_done() {
	local step="$1"
	case "$step" in
	1)
		[[ -f .ansible/bin/activate ]]
		;;
	2)
		[[ -f "ansible/inventory/${CLOUD_ID}.local" ]]
		;;
	3)
		# Registry is up if we get any HTTP response (200 or 401 auth-required both mean it's running)
		[[ $(curl -sk --max-time 3 -o /dev/null -w "%{http_code}" https://localhost:5000/v2/ 2>/dev/null) != "000" ]]
		;;
	4)
		[[ -f "$MARKER_SYNC_OCP" ]]
		;;
	5)
		[[ -f "$MARKER_SYNC_OP" ]]
		;;
	6)
		[[ -f /root/mno/kubeconfig ]]
		;;
	*)
		return 1
		;;
	esac
}

should_skip() {
	local step="$1"
	local label="$2"
	if $RESUME && check_step_done "$step" 2>/dev/null; then
		echo "==> [${step}/6] SKIPPED (already done): ${label}"
		return 0
	fi
	return 1
}

################################################################################
# Image sync summary
# Parses a captured ansible-playbook log for known oc-mirror/oc-adm error
# patterns and prints a grouped count table.
################################################################################
print_sync_summary() {
	local log="$1"
	local step_name="$2"

	local manifest_unknown unauthorized bundle_skipped failed_copy other_errors
	manifest_unknown=$(grep -ciE 'manifest.?unknown' "$log" 2>/dev/null || true)
	unauthorized=$(grep -ciE 'unauthorized|access.?denied' "$log" 2>/dev/null || true)
	bundle_skipped=$(grep -ciE 'bundle.*skip|skip.*bundle' "$log" 2>/dev/null || true)
	# oc mirror v2 reports copy failures as: [ERROR] : Failed to copy ...
	failed_copy=$(grep -ciE '\[ERROR\].*[Ff]ailed to copy' "$log" 2>/dev/null || true)

	# Count remaining error lines not covered by the specific categories above
	other_errors=$(grep -iE 'level=error|\[ERROR\]|FAILED!' "$log" 2>/dev/null \
		| grep -civE 'manifest.?unknown|unauthorized|access.?denied|bundle.*skip|skip.*bundle|[Ff]ailed to copy' \
		|| true)

	local total=$(( ${manifest_unknown:-0} + ${unauthorized:-0} + ${bundle_skipped:-0} + ${failed_copy:-0} + ${other_errors:-0} ))

	echo ""
	echo "  --- ${step_name} image sync summary ---"
	if [[ $total -eq 0 ]]; then
		echo "  All images synced successfully (no errors detected)."
	else
		printf "  %-22s %s\n" "Error type" "Count"
		printf "  %-22s %s\n" "----------" "-----"
		[[ $manifest_unknown -gt 0 ]] && printf "  %-22s %d\n" "manifest-unknown" "$manifest_unknown"
		[[ $unauthorized -gt 0 ]]     && printf "  %-22s %d\n" "unauthorized" "$unauthorized"
		[[ $bundle_skipped -gt 0 ]]   && printf "  %-22s %d\n" "bundle skipped" "$bundle_skipped"
		[[ $failed_copy -gt 0 ]]      && printf "  %-22s %d\n" "failed to copy" "$failed_copy"
		[[ $other_errors -gt 0 ]]     && printf "  %-22s %d\n" "other errors" "$other_errors"
	fi
	echo "  Full log: ${log}"
	echo ""
}

################################################################################
# Vars patching
################################################################################
patch_yaml_scalar() {
	local file="$1" key="$2" value="$3"
	sed -i "s|^${key}:.*$|${key}: ${value}|" "$file"
}

patch_rhoai_vars() {
	if [[ -n "$RHOAI_CATALOG" ]]; then
		echo "      Patching RHOAI catalog → ${RHOAI_CATALOG}"
		yq -yi '.catalogs_to_sync[0].catalog = "'"${RHOAI_CATALOG}"'"' "$SYNC_OP_VARS"
	fi
	if [[ -n "$RHOAI_FBC_IMAGE" ]]; then
		echo "      Patching RHOAI FBC image → ${RHOAI_FBC_IMAGE}"
		yq -yi '.additional_images += ["'"${RHOAI_FBC_IMAGE}"'"]' "$SYNC_OP_VARS"
	fi
	if [[ -n "$RHOAI_VERSION" ]]; then
		echo "      Patching RHOAI version → ${RHOAI_VERSION}"
		yq -yi '
			.catalogs_to_sync[0].packages[0].channels[0].minVersion = "'"${RHOAI_VERSION}"'" |
			.catalogs_to_sync[0].packages[0].channels[0].maxVersion = "'"${RHOAI_VERSION}"'"
		' "$SYNC_OP_VARS"
	fi
	if [[ -n "$RHOAI_CHANNEL" ]]; then
		echo "      Patching RHOAI channel → ${RHOAI_CHANNEL}"
		yq -yi '
			.catalogs_to_sync[0].packages[0].defaultChannel = "'"${RHOAI_CHANNEL}"'" |
			.catalogs_to_sync[0].packages[0].channels[0].name = "'"${RHOAI_CHANNEL}"'"
		' "$SYNC_OP_VARS"
	fi
}

patch_nodes_override() {
	local file
	file="$(realpath "$1")"
	[[ -f "$file" ]] || die "--nodes-override: file not found: ${file}"
	if grep -q '^ocp_inventory_override:' "$ALL_VARS"; then
		sed -i "s|^ocp_inventory_override:.*$|ocp_inventory_override: ${file}|" "$ALL_VARS"
	else
		echo "ocp_inventory_override: ${file}" >> "$ALL_VARS"
	fi
	echo "      ocp_inventory_override → ${file}"
}

################################################################################
# Argument parsing
################################################################################
[[ $# -eq 0 ]] && usage

CLOUD_ID="${1}"
shift

while [[ $# -gt 0 ]]; do
	case "$1" in
	--ocp-version)     OCP_VERSION="$2";     shift 2 ;;
	--ocp-build)       OCP_BUILD="$2";       shift 2 ;;
	--rhoai-catalog)   RHOAI_CATALOG="$2";   shift 2 ;;
	--rhoai-fbc-image) RHOAI_FBC_IMAGE="$2"; shift 2 ;;
	--rhoai-version)   RHOAI_VERSION="$2";   shift 2 ;;
	--rhoai-channel)   RHOAI_CHANNEL="$2";   shift 2 ;;
	--nodes-override)  NODES_OVERRIDE="$2";  shift 2 ;;
	--resume)          RESUME=true; shift ;;
	-h|--help) usage ;;
	*) die "Unknown argument: $1" ;;
	esac
done

[[ -z "$CLOUD_ID" ]] && { echo "Error: cloud allocation id is required."; usage; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

INVENTORY="ansible/inventory/${CLOUD_ID}.local"
mkdir -p "$LOGS_DIR"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

LOG_DEPLOY="${LOGS_DIR}/${CLOUD_ID}-deploy-${TIMESTAMP}.log"
exec > >(tee "$LOG_DEPLOY") 2>&1
echo "Deploy log: ${LOG_DEPLOY}"

################################################################################
# Step 1: Bootstrap venv
################################################################################
if ! should_skip 1 "Bootstrap ansible virtual environment"; then
	echo "==> [1/6] Bootstrap ansible virtual environment"
	if [[ ! -f .ansible/bin/activate ]]; then
		source bootstrap.sh
	else
		source .ansible/bin/activate
	fi
else
	[[ -f .ansible/bin/activate ]] && source .ansible/bin/activate
fi

################################################################################
# Step 2: Prepare vars and generate inventory
################################################################################
if ! should_skip 2 "Prepare vars and generate inventory for ${CLOUD_ID}"; then
	echo "==> [2/6] Prepare vars and generate inventory for ${CLOUD_ID}"

	patch_yaml_scalar "$ALL_VARS" "lab_cloud" "${CLOUD_ID}"
	echo "      lab_cloud → ${CLOUD_ID}"

	if [[ -n "$OCP_VERSION" ]]; then
		patch_yaml_scalar "$ALL_VARS" "ocp_version" "\"${OCP_VERSION}\""
		patch_yaml_scalar "$SYNC_OCP_VARS" "ocp_version" "\"${OCP_VERSION}\""
		echo "      ocp_version → ${OCP_VERSION}"
	fi

	if [[ -n "$OCP_BUILD" ]]; then
		patch_yaml_scalar "$ALL_VARS" "ocp_build" "\"${OCP_BUILD}\""
		patch_yaml_scalar "$SYNC_OCP_VARS" "ocp_build" "\"${OCP_BUILD}\""
		echo "      ocp_build → ${OCP_BUILD}"
	fi

	[[ -n "$RHOAI_CATALOG" || -n "$RHOAI_FBC_IMAGE" || -n "$RHOAI_VERSION" || -n "$RHOAI_CHANNEL" ]] \
		&& patch_rhoai_vars

	[[ -n "$NODES_OVERRIDE" ]] && patch_nodes_override "$NODES_OVERRIDE"

	ansible-playbook ansible/create-inventory.yml
	[[ -f "$INVENTORY" ]] || die "inventory file '${INVENTORY}' was not created."
fi

################################################################################
# Step 3: Setup bastion
################################################################################
if ! should_skip 3 "Setup bastion (registry, DNS, Assisted Installer)"; then
	echo "==> [3/6] Setup bastion (registry, DNS, Assisted Installer)"
	# Force-remove AI service containers before setup so they are always recreated
	# with the current onprem-environment (state: started won't restart running containers).
	# Safe on first run - no-op if containers don't exist yet.
	ansible -i "$INVENTORY" bastion -m shell -a \
		"podman container stop service image-service 2>/dev/null; podman container rm service image-service 2>/dev/null; true" \
		|| true
	ansible-playbook -i "$INVENTORY" ansible/setup-bastion.yml
fi

################################################################################
# Step 4: Sync OCP release images
################################################################################
if ! should_skip 4 "Sync OCP release images to bastion registry"; then
	echo "==> [4/6] Sync OCP release images to bastion registry"
	LOG_SYNC_OCP="${LOGS_DIR}/${CLOUD_ID}-sync-ocp-${TIMESTAMP}.log"
	ansible-playbook -i "$INVENTORY" ansible/sync-ocp-release.yml 2>&1 | tee "$LOG_SYNC_OCP"
	touch "$MARKER_SYNC_OCP"
	print_sync_summary "$LOG_SYNC_OCP" "OCP release"
fi

################################################################################
# Step 5: Sync operator index + additional images
################################################################################
if ! should_skip 5 "Sync operator index + additional images to bastion registry"; then
	echo "==> [5/6] Sync operator index + additional images to bastion registry"
	LOG_SYNC_OP="${LOGS_DIR}/${CLOUD_ID}-sync-operators-${TIMESTAMP}.log"
	ansible-playbook -i "$INVENTORY" ansible/sync-operator-index.yml 2>&1 | tee "$LOG_SYNC_OP"
	touch "$MARKER_SYNC_OP"

	# Overwrite the deploy-log with the oc mirror internal log (more meaningful than ansible output)
	OPERATOR_INDEX_NAME=$(grep -m1 '^operator_index_name:' "$SYNC_OP_VARS" 2>/dev/null \
		| awk '{print $2}' | tr -d '"' || true)
	[[ -z "${OPERATOR_INDEX_NAME:-}" ]] && OPERATOR_INDEX_NAME="redhat-operator-index"
	OC_MIRROR_LOG=$(ls -t "/opt/registry/sync/operators/${OPERATOR_INDEX_NAME}/working-dir/logs"/oc-mirror-*.log 2>/dev/null | head -1 || true)
	[[ -n "${OC_MIRROR_LOG:-}" ]] && cp "$OC_MIRROR_LOG" "$LOG_SYNC_OP"

	print_sync_summary "$LOG_SYNC_OP" "Operator index"
fi

################################################################################
# Step 6: Deploy MNO cluster
################################################################################
if ! should_skip 6 "Deploy MNO cluster"; then
	echo "==> [6/6] Deploy MNO cluster"
	ansible-playbook -i "$INVENTORY" ansible/mno-deploy.yml
fi

echo ""
echo "Deployment complete. Access the cluster from the bastion:"
echo "  export KUBECONFIG=/root/mno/kubeconfig"
echo "  oc get nodes"
echo "  cat /root/mno/kubeadmin-password"
