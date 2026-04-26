#!/usr/bin/env bash
# deploy.sh - End-to-end disconnected MNO deployment on Performance Lab bare metal
#
# Usage: ./deploy.sh <cloud-id> [OPTIONS]
#   e.g. ./deploy.sh cloud02
#        ./deploy.sh cloud02 --ocp-version 4.20.1 --rhoai-version 3.4.0-ea.2  # also should support FBC image
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
REFRESH_NODES=false

HW_CONFIG="ansible/vars/hw-config.yml"
ALL_VARS="ansible/vars/all.yml"
SYNC_OCP_VARS="ansible/vars/sync-ocp-release.yml"
SYNC_OP_VARS="ansible/vars/sync-operator-index.yml"

DISCONNECTED_IMAGESET_REPO=""  # overridable via --imageset-repo; defaults to internal GitLab URL
DISCONNECTED_IMAGESET_DIR="/tmp/disconnected-imageset"
GO_YQ="/usr/local/bin/yq"
# GITLAB_TOKEN must be set in the environment when cloning from gitlab.cee.redhat.com.
# It is intentionally not a CLI flag to avoid the token appearing in shell history or ps output.

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
  --rhoai-fbc-image URL     RHOAI FBC image; drives disconnected-imageset automation.
                            Always pair with --rhoai-channel: the channel is auto-derived
                            from the FBC image label but upstream logic may misclassify
                            EA releases (e.g. 3.4.0-ea.2 → stable-3.x instead of beta).
  --rhoai-version VERSION   RHOAI operator version override (e.g. 3.4.0-ea.2)
  --rhoai-channel CHANNEL   RHOAI operator channel (e.g. beta, stable-3.x). Required
                            alongside --rhoai-fbc-image for EA/pre-GA releases.
  --imageset-repo URL       Override disconnected-imageset Git URL (default: internal GitLab).
                            Set GITLAB_TOKEN env var for authentication when using the default URL.
  --nodes-override FILE     Path to custom ocpinventory.json; skips node refresh
  --refresh-nodes           Refresh nodes-override.json from QUADS + Redfish before
                            deployment (picks up MAC or cabling changes). Requires
                            ansible/vars/hw-config.yml — run --init first if missing.
  --resume                  Auto-detect completed steps and skip them
  -h, --help                Show this help

Steps:
  1    Bootstrap ansible virtual environment
  2    Prepare vars and generate inventory for <cloud-id>
  3    Setup bastion (registry, DNS, Assisted Installer)
  4    Sync OCP release images to bastion registry
  5    Sync operator index + additional images to bastion registry
  6    Deploy MNO cluster
  post Generate cluster artifacts under /root/mno/:
         registry-ca-configmap.yaml  — CA ConfigMap for openshift-config namespace
         image-config-patch.yaml     — patches image.config.openshift.io/cluster to trust
                                       the bastion registry CA (MCO propagates to all nodes)

  Node refresh (run when hardware changes — NIC swap, firmware update, re-cabling):
    python3 scripts/generate-nodes-override.py --init --cloud <cloud-id>  # first-time
    ./deploy.sh <cloud-id> --refresh-nodes                                 # on deploy

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

clone_disconnected_imageset() {
	local repo_url="${DISCONNECTED_IMAGESET_REPO}"

	# Build the default internal GitLab URL, embedding GITLAB_TOKEN if set
	if [[ -z "${repo_url}" ]]; then
		local base_url="gitlab.cee.redhat.com/ods/disconnected-imageset.git"
		if [[ -n "${GITLAB_TOKEN:-}" ]]; then
			repo_url="https://oauth2:${GITLAB_TOKEN}@${base_url}"
		else
			repo_url="https://${base_url}"
			echo "      WARNING: GITLAB_TOKEN is not set — clone may fail if repo requires authentication"
		fi
	fi

	if [[ -d "${DISCONNECTED_IMAGESET_DIR}/.git" ]]; then
		echo "      disconnected-imageset: pulling latest..."
		git -C "${DISCONNECTED_IMAGESET_DIR}" -c http.sslVerify=false pull --ff-only 2>/dev/null \
			|| echo "      WARNING: could not pull disconnected-imageset, using cached clone"
	else
		echo "      Cloning disconnected-imageset..."
		git -c http.sslVerify=false clone "${repo_url}" "${DISCONNECTED_IMAGESET_DIR}"
	fi
}

# Maps an OLM version string to the matching imagesets/v2/rhoai-* directory.
#   3.4.0-ea.2  →  rhoai-3.4.EA2
#   3.3.1       →  rhoai-3.3.1.GA
#   3.3.0       →  rhoai-3.3.GA
find_rhoai_version_dir() {
	local base_dir="${1}" olm_version="${2}"
	local dir_name major minor patch ea_num

	if [[ "${olm_version}" == *"-ea."* ]]; then
		major=$(echo "${olm_version}" | awk -F'.' '{print $1}')
		minor=$(echo "${olm_version}" | awk -F'.' '{print $2}')
		ea_num=$(echo "${olm_version}" | sed 's/.*-ea\.//')
		dir_name="rhoai-${major}.${minor}.EA${ea_num}"
	else
		major=$(echo "${olm_version}" | awk -F'.' '{print $1}')
		minor=$(echo "${olm_version}" | awk -F'.' '{print $2}')
		patch=$(echo "${olm_version}" | awk -F'.' '{print $3}')
		if [[ -z "${patch}" || "${patch}" == "0" ]]; then
			dir_name="rhoai-${major}.${minor}.GA"
		else
			dir_name="rhoai-${major}.${minor}.${patch}.GA"
		fi
	fi

	local full_path="${base_dir}/imagesets/v2/${dir_name}"
	[[ -d "${full_path}" ]] && echo "${full_path}" || echo ""
}

# Runs all disconnected-imageset generate scripts for the given FBC image + OCP version and
# merges the results into sync-operator-index.yml:
#   - additional_images: union of images from all four sources (rhoai-ci, rhoai-{version},
#                        dependent-operators, custom-images), deduplicated
#   - catalogs_to_sync[*].catalog: pinned to immutable digests from ocp-digests.yaml
#     (redhat-operator-index and community-operator-index) via dependent-operators/generate.sh
#   - RHOAI_CATALOG / RHOAI_VERSION / RHOAI_CHANNEL: auto-derived from the FBC image label
#     unless already set via manual flags (patch_rhoai_vars applies those overrides after)
populate_rhoai_images() {
	local imagesets_dir="${DISCONNECTED_IMAGESET_DIR}/imagesets/v2"
	local pull_secret="${SCRIPT_DIR}/pull-secret.txt"
	local tmp_merged
	tmp_merged=$(mktemp)

	# Normalize OCP_VERSION for disconnected-imageset scripts: strip any leading qualifier
	# (e.g. latest-4.19 → 4.19, ci-4.20.0-0.nightly-... → 4.20) so template lookup works
	local ocp_ver_numeric
	ocp_ver_numeric=$(echo "${OCP_VERSION}" | sed 's/^[a-z]*-//' | awk -F'.' '{print $1"."$2}')

	clone_disconnected_imageset

	# 1. rhoai-ci: inspect FBC image → catalog/channel/version + additional images
	echo "      [imageset] rhoai-ci: inspecting FBC image ${RHOAI_FBC_IMAGE}..."
	local rhoai_ci_dir="${imagesets_dir}/rhoai-ci"
	(
		export PATH="/usr/local/bin:${PATH}"
		export FBC_IMAGE="${RHOAI_FBC_IMAGE}"
		export AUTH_FILE="${pull_secret}"
		cd "${DISCONNECTED_IMAGESET_DIR}"
		bash "${rhoai_ci_dir}/generate.sh"
	) >/dev/null
	local rhoai_ci_isc="${rhoai_ci_dir}/isc.yaml"
	[[ -z "${RHOAI_CATALOG}" ]] && \
		RHOAI_CATALOG=$("${GO_YQ}" e '.mirror.operators[0].catalog' "${rhoai_ci_isc}")
	[[ -z "${RHOAI_VERSION}" ]] && \
		RHOAI_VERSION=$("${GO_YQ}" e '.mirror.operators[0].packages[0].channels[0].minVersion' "${rhoai_ci_isc}")
	local channel_explicit="${RHOAI_CHANNEL}"  # non-empty only if --rhoai-channel was passed
	[[ -z "${RHOAI_CHANNEL}" ]] && \
		RHOAI_CHANNEL=$("${GO_YQ}" e '.mirror.operators[0].packages[0].defaultChannel' "${rhoai_ci_isc}")
	# Warn when channel is auto-derived for an EA version: upstream get_rhoai_channel()
	# truncates "3.4.0-ea.2" → "3.4" before the EA check, so it may return stable-3.x
	# instead of beta. Caller should always pass --rhoai-channel for EA/pre-GA releases.
	if [[ -z "${channel_explicit}" && -n "${RHOAI_VERSION}" && "${RHOAI_VERSION,,}" == *ea* ]]; then
		echo "      [imageset] WARNING: channel auto-derived as '${RHOAI_CHANNEL}' for EA version ${RHOAI_VERSION} — this may be wrong. Pass --rhoai-channel explicitly (e.g. --rhoai-channel beta)."
	fi
	"${GO_YQ}" e '.mirror.additionalImages[].name' "${rhoai_ci_isc}" >> "${tmp_merged}"
	echo "      [imageset] rhoai-ci: $("${GO_YQ}" e '.mirror.additionalImages | length' "${rhoai_ci_isc}") images (catalog=${RHOAI_CATALOG}, version=${RHOAI_VERSION}, channel=${RHOAI_CHANNEL})"

	# 2. rhoai-{version}: version-specific workbench + framework images
	if [[ -n "${RHOAI_VERSION}" && -n "${OCP_VERSION}" ]]; then
		local version_dir
		version_dir=$(find_rhoai_version_dir "${DISCONNECTED_IMAGESET_DIR}" "${RHOAI_VERSION}")
		if [[ -n "${version_dir}" ]]; then
			echo "      [imageset] rhoai-version: $(basename "${version_dir}")/generate.sh..."
			(
				export PATH="/usr/local/bin:${PATH}"
				export OCP_VERSION="${ocp_ver_numeric}"
				cd "${DISCONNECTED_IMAGESET_DIR}"
				bash "${version_dir}/generate.sh"
			) >/dev/null
			"${GO_YQ}" e '.mirror.additionalImages[].name' "${version_dir}/isc.yaml" >> "${tmp_merged}"
			echo "      [imageset] rhoai-version: $("${GO_YQ}" e '.mirror.additionalImages | length' "${version_dir}/isc.yaml") images"
		else
			echo "      [imageset] WARNING: no imagesets/v2 directory found for ${RHOAI_VERSION} — skipping version-specific images"
		fi
	fi

	# 3. dependent-operators: OCP-version-pinned operator dependencies
	#    Also extracts digest-pinned catalog URLs to replace the floating tags in catalogs_to_sync
	if [[ -n "${OCP_VERSION}" ]]; then
		echo "      [imageset] dependent-operators: OCP ${OCP_VERSION}..."
		(
			export PATH="/usr/local/bin:${PATH}"
			export OCP_VERSION="${ocp_ver_numeric}"
			cd "${DISCONNECTED_IMAGESET_DIR}"
			bash "${imagesets_dir}/dependent-operators/generate.sh"
		) >/dev/null
		local dep_ops_isc="${imagesets_dir}/dependent-operators/isc.yaml"
		"${GO_YQ}" e '.mirror.additionalImages[].name' "${dep_ops_isc}" >> "${tmp_merged}"
		echo "      [imageset] dependent-operators: $("${GO_YQ}" e '.mirror.additionalImages | length' "${dep_ops_isc}") images"

		# Pin redhat-operator-index and community-operator-index to immutable digests
		local pinned_rh_catalog pinned_community_catalog
		pinned_rh_catalog=$("${GO_YQ}" e \
			'.mirror.operators[] | select(.catalog | test("redhat-operator-index")) | .catalog' \
			"${dep_ops_isc}")
		pinned_community_catalog=$("${GO_YQ}" e \
			'.mirror.operators[] | select(.catalog | test("community-operator-index")) | .catalog' \
			"${dep_ops_isc}")

		if [[ -n "${pinned_rh_catalog}" && "${pinned_rh_catalog}" == *"@sha256:"* ]]; then
			echo "      [imageset] pinning redhat-operator-index → ${pinned_rh_catalog}"
			yq -yi \
				'(.catalogs_to_sync[] | select(.target_catalog == "redhat/redhat-operator-index") | .catalog) = "'"${pinned_rh_catalog}"'"' \
				"${SYNC_OP_VARS}"
		fi
		if [[ -n "${pinned_community_catalog}" && "${pinned_community_catalog}" == *"@sha256:"* ]]; then
			echo "      [imageset] pinning community-operator-index → ${pinned_community_catalog}"
			yq -yi \
				'(.catalogs_to_sync[] | select(.target_catalog == "redhat/community-operator-index") | .catalog) = "'"${pinned_community_catalog}"'"' \
				"${SYNC_OP_VARS}"
		fi
	else
		echo "      [imageset] WARNING: --ocp-version not set — skipping dependent-operators and catalog digest pinning"
	fi

	# 4. custom-images: static test infrastructure images
	echo "      [imageset] custom-images: static list..."
	"${GO_YQ}" e '.mirror.additionalImages[].name' "${imagesets_dir}/custom-images/isc.yaml" >> "${tmp_merged}"
	echo "      [imageset] custom-images: $("${GO_YQ}" e '.mirror.additionalImages | length' "${imagesets_dir}/custom-images/isc.yaml") images"

	# Deduplicate
	sort -u -o "${tmp_merged}" "${tmp_merged}"

	# Warn about rate-limited registries
	local rate_limited
	rate_limited=$(grep -E '^(docker\.io/|ghcr\.io/|docker-registry1\.)' "${tmp_merged}" || true)
	if [[ -n "${rate_limited}" ]]; then
		echo "      [imageset] WARNING: images from rate-limited registries (docker.io/ghcr.io) — may hit pull quotas:"
		echo "${rate_limited}" | sed 's/^/        /'
	fi

	# Merge into sync-operator-index.yml (union with existing additional_images)
	local existing_images all_images images_json
	existing_images=$(yq -r '.additional_images // [] | .[]' "${SYNC_OP_VARS}" 2>/dev/null || true)
	all_images=$(printf "%s\n%s\n" "${existing_images}" "$(cat "${tmp_merged}")" \
		| grep -v '^$' | sort -u)
	images_json=$(echo "${all_images}" | jq -Rn '[inputs]')
	yq -yi ".additional_images = ${images_json}" "${SYNC_OP_VARS}"

	echo "      [imageset] merged $(echo "${all_images}" | grep -c .) total additional_images into ${SYNC_OP_VARS}"
	rm -f "${tmp_merged}"
}

patch_rhoai_vars() {
	if [[ -n "$RHOAI_CATALOG" ]]; then
		echo "      Patching RHOAI catalog → ${RHOAI_CATALOG}"
		yq -yi '.catalogs_to_sync[0].catalog = "'"${RHOAI_CATALOG}"'"' "$SYNC_OP_VARS"
	fi
	if [[ -n "$RHOAI_FBC_IMAGE" ]]; then
		echo "      Patching RHOAI FBC image → ${RHOAI_FBC_IMAGE}"
		yq -yi '.additional_images += ["'"${RHOAI_FBC_IMAGE}"'"]' "$SYNC_OP_VARS"
		# EA/pre-GA RHOAI images are published to quay.io/rhoai, not registry.redhat.io/rhoai.
		# The registries.conf.d redirect is required for oc-mirror to resolve them.
		yq -yi '.sync_rhoai_registries_conf = true' "$SYNC_OP_VARS"
		echo "      sync_rhoai_registries_conf → true (required for RHOAI FBC image mirroring)"
	fi
	if [[ -n "$OCP_VERSION" ]]; then
		local ocp_tag
		ocp_tag="v$(echo "${OCP_VERSION}" | sed 's/^[a-z]*-//' | awk -F'.' '{print $1"."$2}')"
		echo "      Patching operator_index_tag → ${ocp_tag}"
		yq -yi ".operator_index_tag = \"${ocp_tag}\"" "$SYNC_OP_VARS"
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
	--rhoai-catalog)   RHOAI_CATALOG="$2";              shift 2 ;;
	--rhoai-fbc-image) RHOAI_FBC_IMAGE="$2";            shift 2 ;;
	--rhoai-version)   RHOAI_VERSION="$2";              shift 2 ;;
	--rhoai-channel)   RHOAI_CHANNEL="$2";              shift 2 ;;
	--imageset-repo)   DISCONNECTED_IMAGESET_REPO="$2"; shift 2 ;;
	--nodes-override)  NODES_OVERRIDE="$2";  shift 2 ;;
	--refresh-nodes)   REFRESH_NODES=true; shift ;;
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
# Step 1b: Refresh nodes-override.json (opt-in via --refresh-nodes)
################################################################################
if $REFRESH_NODES && [[ -z "$NODES_OVERRIDE" ]]; then
	echo "==> [1b] Refresh nodes-override.json from QUADS + Redfish"
	if [[ ! -f "$HW_CONFIG" ]]; then
		echo "      hw-config.yml not found — running --init to bootstrap it ..."
		python3 scripts/generate-nodes-override.py --init --cloud "${CLOUD_ID}" --hw-config "${HW_CONFIG}"
		echo "      Review ${HW_CONFIG} and re-run if the detected roles or adapters need adjustment."
	fi
	python3 scripts/generate-nodes-override.py \
		--cloud "${CLOUD_ID}" \
		--hw-config "${HW_CONFIG}" \
		--output nodes-override.json
	if grep -q '^ocp_inventory_override:' "$ALL_VARS"; then
		sed -i "s|^ocp_inventory_override:.*$|ocp_inventory_override: $(pwd)/nodes-override.json|" "$ALL_VARS"
	else
		echo "ocp_inventory_override: $(pwd)/nodes-override.json" >> "$ALL_VARS"
	fi
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

	if [[ -n "${RHOAI_FBC_IMAGE}" ]]; then
		populate_rhoai_images
	fi
	# Apply any manual --rhoai-* flag overrides on top of values derived above
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

################################################################################
# Post-deployment: generate cluster artifacts
################################################################################
echo "==> [post] Generating cluster artifacts"

# Registry CA manifests — apply these after the cluster is up so RHOAI/cluster
# components trust the bastion self-signed registry CA.
# Set DSCI spec.trustedCABundle.managementState: Managed to inherit the cluster bundle.
_bastion_fqdn=$(hostname -f)
_ca_cert="/opt/registry/certs/domain.crt"
_mno_dir="/root/mno"
# OpenShift additionalTrustedCA key format: <hostname>..<port> with dots in hostname
# replaced by .. (double-dot) per OCP convention, e.g. foo..bar..example..com..5000
_registry_key="${_bastion_fqdn//./'..'}..5000"
if [[ -f "${_ca_cert}" ]]; then
	{
		cat <<YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: bastion-registry-ca
  namespace: openshift-config
data:
  ${_registry_key}: |
YAML
		sed 's/^/    /' "${_ca_cert}"
	} > "${_mno_dir}/registry-ca-configmap.yaml"

	cat > "${_mno_dir}/image-config-patch.yaml" <<'YAML'
spec:
  additionalTrustedCA:
    name: bastion-registry-ca
YAML
	echo "      Registry CA manifests → ${_mno_dir}/registry-ca-configmap.yaml"
	echo "      Image config patch    → ${_mno_dir}/image-config-patch.yaml"
else
	echo "      WARNING: ${_ca_cert} not found — registry CA manifests not generated"
fi

# Apply IDMS/ITMS/CatalogSource — mirror redirects and OLM catalog pointer.
# Must run after the cluster is up and after Step 5 has populated working-dir.
_op_idx_name=$(grep -m1 '^operator_index_name:' "$SYNC_OP_VARS" 2>/dev/null \
	| awk '{print $2}' | tr -d '"' || true)
[[ -z "${_op_idx_name}" ]] && _op_idx_name="redhat-operator-index"
_cluster_resources="/opt/registry/sync/operators/${_op_idx_name}/working-dir/cluster-resources"

if [[ -f "${_mno_dir}/kubeconfig" && -d "${_cluster_resources}" ]]; then
	export KUBECONFIG="${_mno_dir}/kubeconfig"
	_applied=0
	for _f in idms-oc-mirror.yaml itms-oc-mirror.yaml catalog-sources.yaml; do
		if [[ -f "${_cluster_resources}/${_f}" ]]; then
			oc apply -f "${_cluster_resources}/${_f}"
			_applied=1
		fi
	done
	if [[ "${_applied}" -eq 1 ]]; then
		echo "      Waiting for MachineConfigPool rollout..."
		oc wait mcp master worker --for condition=updated --timeout=600s || \
			echo "      WARNING: MCP did not reach Updated within 600s — check 'oc get mcp'"
	fi
else
	[[ ! -f "${_mno_dir}/kubeconfig" ]] && \
		echo "      [post] Skipping mirror manifest apply — kubeconfig not found (cluster not yet deployed)"
	[[ ! -d "${_cluster_resources}" ]] && \
		echo "      [post] Skipping mirror manifest apply — ${_cluster_resources} not found (run Step 5 first)"
fi

echo ""
echo "Deployment complete. Access the cluster from the bastion:"
echo "  export KUBECONFIG=/root/mno/kubeconfig"
echo "  oc get nodes"
echo "  cat /root/mno/kubeadmin-password"
echo ""
echo "Apply registry CA trust (required before installing RHOAI):"
echo "  oc apply -f /root/mno/registry-ca-configmap.yaml"
echo "  oc patch image.config.openshift.io/cluster --type=merge --patch-file /root/mno/image-config-patch.yaml"
