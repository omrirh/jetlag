#!/usr/bin/env bash
# deploy_rhoai_bm_utils.sh — helper functions sourced by deploy_rhoai_bm.sh
# Do not execute directly. All functions reference globals set in deploy_rhoai_bm.sh.

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

Post-install options (steps 8-11, run after cluster is up):
  --gpu-operator nvidia     Mirror nvidia-operator imageset (step 2) and install NFD +
                            NVIDIA GPU operator on the cluster (step 9).
  --s3-mirror-config CFG    disconnected-s3 config name to mirror from AWS S3 → bastion
                            Minio (step 8). Use 'all-smoke' for the llm-d smoke test
                            dataset. Requires AWS_* in credentials.env and --s3-repo.
  --s3-repo URL             Clone URL for disconnected-s3 (internal GitLab). Requires
                            GITLAB_TOKEN in credentials.env.
  --rhoai-update-channel CH Install RHOAI via olminstall after cluster deploy (step 10).
                            Channel examples: beta, fast, stable-3.x.
  --rhoai-catalog-source CS CatalogSource name for rhods-operator Subscription
                            (default: rhoai-catalog-dev, hardcoded in olminstall).
  --olminstall-repo URL     Override olminstall clone URL (default: internal GitLab).
  --add-custom-ca-bundles   Append bastion CA certs (registry, Minio, PyPI, Git) to
                            DSCI spec.trustedCABundle.customCABundle (step 11).
  --cleanup-rhoai           Run olminstall cleanup.sh -t operator before step 10.
  --skip-image-repair       Skip the preflight registry blob repair scan (steps 9-10).
                            Use when re-deploying a different RHOAI version on the
                            same cluster.

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
         cluster-info.env            — machine-readable env file (API URL, apps domain, paths)

  Node refresh (run when hardware changes — NIC swap, firmware update, re-cabling):
    python3 scripts/generate-nodes-override.py --init --cloud <cloud-id>  # first-time
    ./deploy_rhoai_bm.sh <cloud-id> --refresh-nodes                       # on deploy

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
		[[ -f "${MNO_DIR}/kubeconfig" ]]
		;;
	7)
		# IDMS applied and MCP rollout done: idms-operator-0 exists on the cluster
		KUBECONFIG="${MNO_DIR}/kubeconfig" \
			oc get imagedigestmirrorset idms-operator-0 &>/dev/null 2>&1
		;;
	9)
		KUBECONFIG="${MNO_DIR}/kubeconfig" \
			oc get csv -A --no-headers 2>/dev/null | grep -q 'gpu-operator.*Succeeded'
		;;
	10)
		KUBECONFIG="${MNO_DIR}/kubeconfig" \
			oc get csv -n redhat-ods-operator --no-headers 2>/dev/null | grep -q 'rhods-operator.*Succeeded' \
		&& KUBECONFIG="${MNO_DIR}/kubeconfig" \
			oc get datasciencecluster default-dsc &>/dev/null 2>&1
		;;
	11)
		KUBECONFIG="${MNO_DIR}/kubeconfig" \
			oc get dsci default-dsci -o 'jsonpath={.spec.trustedCABundle.customCABundle}' 2>/dev/null \
			| grep -q .
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
		echo "==> [${step}] SKIPPED (already done): ${label}"
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

	# upstream utils.sh uses `keys[]` which is Go yq v3 syntax rejected by v4.
	# Patch in-place after every pull so the fix survives repo updates.
	local _utils="${DISCONNECTED_IMAGESET_DIR}/lib/utils.sh"
	if [[ -f "${_utils}" ]] && grep -q 'keys\[\]' "${_utils}"; then
		sed -i 's/| keys\[\]/| keys | .[]/g' "${_utils}"
		echo "      [patch] utils.sh: keys[] → keys | .[] (Go yq v4 compat)"
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

		# Merge operator packages from the version-specific isc.yaml into catalogs_to_sync.
		# The version-specific templates (e.g. isc-v4.20.yaml.template) include RHOAI 3.x
		# dependency operators (kueue, rhcl, cert-manager, lws, job-set, etc.) that are absent
		# from isc-default.yaml.template. Merging here keeps disconnected-imageset authoritative.
		_merge_catalog_packages "${dep_ops_isc}" "redhat-operator-index" "redhat/redhat-operator-index"
		_merge_catalog_packages "${dep_ops_isc}" "community-operator-index" "redhat/community-operator-index"
	else
		echo "      [imageset] WARNING: --ocp-version not set — skipping dependent-operators and catalog digest pinning"
	fi

	# 4. custom-images: static test infrastructure images
	echo "      [imageset] custom-images: static list..."
	"${GO_YQ}" e '.mirror.additionalImages[].name' "${imagesets_dir}/custom-images/isc.yaml" >> "${tmp_merged}"
	echo "      [imageset] custom-images: $("${GO_YQ}" e '.mirror.additionalImages | length' "${imagesets_dir}/custom-images/isc.yaml") images"

	# 5. nvidia-operator: GPU operator images + certified-operator-index catalog
	if [[ "${GPU_OPERATOR,,}" == "nvidia" ]]; then
		local nvidia_dir="${imagesets_dir}/nvidia-operator"
		if [[ -d "${nvidia_dir}" ]]; then
			echo "      [imageset] nvidia-operator: running generate.sh..."
			(
				export PATH="/usr/local/bin:${PATH}"
				export OCP_VERSION="${ocp_ver_numeric}"
				cd "${DISCONNECTED_IMAGESET_DIR}"
				bash "${nvidia_dir}/generate.sh"
			) >/dev/null
			local nvidia_isc="${nvidia_dir}/isc.yaml"

			# Catalog index images (certified-operator-index, redhat-operator-index digests)
			"${GO_YQ}" e '.mirror.additionalImages[].name' "${nvidia_isc}" >> "${tmp_merged}"
			echo "      [imageset] nvidia-operator: $("${GO_YQ}" e '.mirror.additionalImages | length' "${nvidia_isc}") catalog index images"

			# Add certified-operator-index as a new catalogs_to_sync entry (gpu-operator-certified)
			local _cert_catalog_url
			_cert_catalog_url=$("${GO_YQ}" e \
				'.mirror.operators[] | select(.catalog | test("certified-operator-index")) | .catalog' \
				"${nvidia_isc}" | head -1)
			if [[ -n "${_cert_catalog_url}" ]]; then
				local _already_has
				_already_has=$("${GO_YQ}" e \
					'.catalogs_to_sync[] | select(.target_catalog == "redhat/certified-operator-index") | .target_catalog' \
					"${SYNC_OP_VARS}" 2>/dev/null || true)
				if [[ -z "${_already_has}" ]]; then
					local _cert_pkgs_json
					_cert_pkgs_json=$("${GO_YQ}" e -o=json --indent 0 \
						'.mirror.operators[] | select(.catalog | test("certified-operator-index")) | .packages' \
						"${nvidia_isc}")
					local _cert_entry
					_cert_entry=$(printf \
						'{"catalog":"%s","target_catalog":"redhat/certified-operator-index","catalog_source_name":"certified-operators","packages":%s}' \
						"${_cert_catalog_url}" "${_cert_pkgs_json}")
					"${GO_YQ}" e -i ".catalogs_to_sync += [${_cert_entry}]" "${SYNC_OP_VARS}"
					echo "      [imageset] nvidia-operator: certified-operator-index → ${_cert_catalog_url}"
				else
					echo "      [imageset] nvidia-operator: certified-operator-index already in catalogs_to_sync"
				fi
			fi

			# Also merge sriov-network-operator from nvidia-operator ISC into redhat-operator-index
			_merge_catalog_packages "${nvidia_isc}" "redhat-operator-index" "redhat/redhat-operator-index"
		else
			echo "      [imageset] WARNING: nvidia-operator dir not found in disconnected-imageset — skipping"
		fi
	fi

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

# Merge operator packages from a disconnected-imageset isc.yaml into catalogs_to_sync.
# Adds packages that are present in the ISC but absent from the sync vars file,
# leaving existing entries (and their version pins) untouched.
_merge_catalog_packages() {
	local _isc="${1}" _catalog_pattern="${2}" _target_catalog="${3}"
	local _added=0 _pkg_name _existing _pkg_json

	while IFS= read -r _pkg_name; do
		[[ -z "${_pkg_name}" ]] && continue
		_existing=$("${GO_YQ}" e \
			'.catalogs_to_sync[] | select(.target_catalog == "'"${_target_catalog}"'") | .packages[] | select(.name == "'"${_pkg_name}"'") | .name' \
			"${SYNC_OP_VARS}" 2>/dev/null || true)
		if [[ -z "${_existing}" ]]; then
			_pkg_json=$("${GO_YQ}" e -o=json --indent 0 \
				'.mirror.operators[] | select(.catalog | test("'"${_catalog_pattern}"'")) | .packages[] | select(.name == "'"${_pkg_name}"'")' \
				"${_isc}" | head -1)
			"${GO_YQ}" e -i \
				'(.catalogs_to_sync[] | select(.target_catalog == "'"${_target_catalog}"'") | .packages) += ['"${_pkg_json}"']' \
				"${SYNC_OP_VARS}"
			_added=$(( _added + 1 ))
		fi
	done < <("${GO_YQ}" e \
		'.mirror.operators[] | select(.catalog | test("'"${_catalog_pattern}"'")) | .packages[].name' \
		"${_isc}" 2>/dev/null)

	if [[ ${_added} -gt 0 ]]; then
		echo "      [packages] +${_added} operator(s) → ${_target_catalog}"
	fi
}

################################################################################
# Registry image repair
#
# oc-mirror v2 occasionally leaves an incomplete blob: the manifest and the
# repository _layers link exist but the blob data file is absent. Result:
# "ImagePullBackOff: unexpected EOF / total 0 bytes" on first pull.
#
# preflight_repair_registry
#   Bulk repair run once before step 9. Scans every repo in the local registry
#   for missing blob data files, then repairs them in a single batch:
#     1. Clear all stale _layers links across all corrupt repos at once.
#     2. One registry restart.
#     3. skopeo copy each corrupt repo from source (registry.redhat.io or nvcr.io).
#   docker.io/ghcr.io-sourced repos are skipped (rate-limited, not part of the
#   GPU/RHOAI operator stack).
#
# repair_pull_failures [namespace ...]
#   Reactive repair run after each install-operator.sh call. Scans pods in
#   ImagePullBackOff and re-copies any corrupt images found.
#   Source registry mapping:
#     strip source registry host → prepend localhost:5000
################################################################################
preflight_repair_registry() {
	local _repo_base="/opt/registry/data/docker/registry/v2/repositories"
	local _blobs_base="/opt/registry/data/docker/registry/v2/blobs/sha256"

	echo "      [preflight-repair] Scanning registry for corrupt blobs..."

	local _corrupt_list
	_corrupt_list=$(python3 << 'PYEOF'
import os, json

repo_base  = "/opt/registry/data/docker/registry/v2/repositories"
blobs_base = "/opt/registry/data/docker/registry/v2/blobs/sha256"

corrupt = {}  # repo → representative digest

for root, dirs, _ in os.walk(repo_base):
    if not root.endswith("/revisions/sha256"):
        continue
    repo = (root
            .replace(repo_base + "/", "")
            .replace("/_manifests/revisions/sha256", ""))
    for digest in sorted(dirs):
        data_path = f"{blobs_base}/{digest[:2]}/{digest}/data"
        if not os.path.exists(data_path):
            corrupt.setdefault(repo, digest)
            continue
        try:
            with open(data_path) as f:
                manifest = json.load(f)
        except Exception:
            continue
        layers_dir = f"{repo_base}/{repo}/_layers/sha256"
        if "manifests" in manifest:
            for m in manifest["manifests"]:
                sd = m["digest"].split(":")[1]
                child_path = f"{blobs_base}/{sd[:2]}/{sd}/data"
                if not os.path.exists(child_path):
                    corrupt.setdefault(repo, digest)
                    break
                try:
                    with open(child_path) as f2:
                        child = json.load(f2)
                except Exception:
                    continue
                for layer in child.get("layers", []):
                    ld = layer["digest"].split(":")[1]
                    if not os.path.exists(f"{layers_dir}/{ld}/link"):
                        corrupt.setdefault(repo, digest)
                        break
                if repo in corrupt:
                    break
        else:
            cfg = manifest.get("config", {}).get("digest", "").split(":")
            if len(cfg) > 1:
                c = cfg[1]
                if not os.path.exists(f"{blobs_base}/{c[:2]}/{c}/data"):
                    corrupt.setdefault(repo, digest)
                    continue
            for layer in manifest.get("layers", []):
                ld = layer["digest"].split(":")[1]
                if not os.path.exists(f"{layers_dir}/{ld}/link"):
                    corrupt.setdefault(repo, digest)
                    break

for repo, digest in sorted(corrupt.items()):
    print(f"{repo}:{digest}")
PYEOF
)

	if [[ -z "${_corrupt_list}" ]]; then
		echo "      [preflight-repair] Registry blobs are intact — nothing to repair."
		return 0
	fi

	local _total
	_total=$(echo "${_corrupt_list}" | wc -l)
	echo "      [preflight-repair] ${_total} repos with corrupt blobs — batch-repairing..."

	# Clear all _layers at once, then restart once
	while IFS= read -r _entry; do
		local _ldir="${_repo_base}/${_entry%%:*}/_layers/sha256"
		[[ -d "${_ldir}" ]] && rm -rf "${_ldir:?}"/* 2>/dev/null || true
	done <<< "${_corrupt_list}"

	echo "      [preflight-repair] Restarting bastion-registry..."
	podman restart bastion-registry &>/dev/null && sleep 8

	local _repaired=0 _failed=0 _skipped=0
	while IFS= read -r _entry; do
		local _repo="${_entry%%:*}"
		local _digest="${_entry##*:}"

		# docker.io / ghcr.io images (mariadb, minio, zot) — skip; not part of
		# the GPU/RHOAI operator stack and subject to rate limits.
		if [[ "${_repo}" == library/* || "${_repo}" == mariadb-operator/* || \
		      "${_repo}" == minio/*   || "${_repo}" == trustyai_testing/* ]]; then
			_skipped=$(( _skipped + 1 ))
			continue
		fi

		local _src_reg="registry.redhat.io"
		[[ "${_repo}" == nvidia/* ]] && _src_reg="nvcr.io"

		echo -n "      [preflight-repair] ${_repo}... "
		if skopeo copy --all \
				--insecure-policy \
				--authfile "${SCRIPT_DIR}/pull-secret.txt" \
				--src-tls-verify=false \
				--dest-tls-verify=false \
				--dest-creds registry:registry \
				--remove-signatures \
				"docker://${_src_reg}/${_repo}@sha256:${_digest}" \
				"docker://localhost:5000/${_repo}" &>/dev/null 2>&1; then
			echo "OK"
			_repaired=$(( _repaired + 1 ))
		else
			echo "FAILED"
			_failed=$(( _failed + 1 ))
		fi
	done <<< "${_corrupt_list}"

	echo "      [preflight-repair] Done: ${_repaired} repaired, ${_failed} failed, ${_skipped} skipped (docker.io/ghcr.io)"
}

################################################################################
# patch_kubeconfig_server
#   Rewrites the kubeconfig server: URL from the internal cluster API VIP to
#   https://<bastion-fqdn>:6443 and enables insecure-skip-tls-verify so that
#   external consumers (Jenkins) can use the file without SSH access to the
#   bastion or a copy of the cluster CA.
#
#   Idempotent: skipped when server: already points to the bastion FQDN.
################################################################################
patch_kubeconfig_server() {
	local _kc="${MNO_DIR}/kubeconfig"
	[[ -f "${_kc}" ]] || { echo "      patch_kubeconfig_server: ${_kc} not found — skipping"; return 0; }

	local _current_server
	_current_server=$(python3 -c "
import yaml, sys
kc = yaml.safe_load(open('${_kc}'))
print(kc['clusters'][0]['cluster'].get('server',''))
" 2>/dev/null || true)

	if [[ "${_current_server}" == "https://${BASTION_FQDN}:6443" ]]; then
		echo "      kubeconfig server: already points to ${BASTION_FQDN} — skipping"
		return 0
	fi

	echo "      Patching kubeconfig server: → https://${BASTION_FQDN}:6443 (insecure-skip-tls-verify)"
	python3 - "${_kc}" "${BASTION_FQDN}" <<'PYEOF'
import sys, yaml
kc_path, fqdn = sys.argv[1], sys.argv[2]
with open(kc_path) as f:
    kc = yaml.safe_load(f)
for cluster in kc.get("clusters", []):
    c = cluster["cluster"]
    c["server"] = f"https://{fqdn}:6443"
    c["insecure-skip-tls-verify"] = True
    c.pop("certificate-authority-data", None)
with open(kc_path, "w") as f:
    yaml.dump(kc, f, default_flow_style=False)
PYEOF
	echo "      kubeconfig patched → ${_kc}"
}

################################################################################
# setup_bastion_proxy
#   Deploys the bastion-proxy Ansible role (Squid on port 3128) and appends
#   SQUID_HTTP_PROXY / SQUID_HTTPS_PROXY to cluster-info.env.
#
#   Idempotent: skipped when the squid container is already running.
################################################################################
setup_bastion_proxy() {
	if podman ps --format '{{.Names}}' 2>/dev/null | grep -q '^squid$'; then
		echo "      Squid proxy already running — skipping"
	else
		echo "      Deploying bastion-proxy role (Squid on port 3128)..."
		ANSIBLE_ROLES_PATH="${SCRIPT_DIR}/ansible/roles" \
			ansible-playbook -i "${INVENTORY}" - <<'YAML' 2>&1 | sed 's/^/      /'
---
- hosts: bastion
  gather_facts: true
  roles:
    - role: bastion-proxy
YAML
	fi

	# Append proxy vars to cluster-info.env (idempotent — overwrite if present)
	local _env_file="${MNO_DIR}/cluster-info.env"
	if [[ -f "${_env_file}" ]]; then
		grep -v "^SQUID_" "${_env_file}" > "${_env_file}.tmp" && mv "${_env_file}.tmp" "${_env_file}"
		cat >> "${_env_file}" <<ENV
SQUID_HTTP_PROXY=http://${BASTION_FQDN}:3128
SQUID_HTTPS_PROXY=http://${BASTION_FQDN}:3128
ENV
		echo "      Proxy vars appended → ${_env_file}"
	fi
}

# cleanup_rhoai — runs olminstall cleanup.sh -t operator to remove a previous
# RHOAI install before deploying a different version.
cleanup_rhoai() {
	local _olminstall_dir="/tmp/olminstall"

	echo "==> [pre-10] RHOAI cleanup (olminstall cleanup.sh -t operator)"
	[[ -f "${MNO_DIR}/kubeconfig" ]] \
		|| die "kubeconfig not found — deploy cluster first"

	if [[ -d "${_olminstall_dir}/.git" ]]; then
		git -C "${_olminstall_dir}" -c http.sslVerify=false pull --ff-only 2>/dev/null || true
	else
		git -c http.sslVerify=false clone "${OLMINSTALL_REPO}" "${_olminstall_dir}"
	fi

	export KUBECONFIG="${MNO_DIR}/kubeconfig"
	cd "${_olminstall_dir}"
	./cleanup.sh -t operator 2>&1 | sed 's/^/      /'
	cd - > /dev/null
	echo "      RHOAI cleanup complete."
}

repair_pull_failures() {
	# Use caller's KUBECONFIG if already set; fall back to MNO_DIR default.
	[[ -z "${KUBECONFIG:-}" ]] && export KUBECONFIG="${MNO_DIR}/kubeconfig"

	local _ns_flag
	if [[ $# -eq 0 ]]; then
		_ns_flag="--all-namespaces"
	else
		_ns_flag="-n $1"
		shift
		for _extra; do _ns_flag+=" -n ${_extra}"; done
		# oc accepts only one -n; use --field-selector with comma-separated
		# namespaces is not supported. Workaround: join with grep post-filter.
		# Simplest: just use --all-namespaces when multiple namespaces given.
		_ns_flag="--all-namespaces"
	fi

	echo "      [repair] Scanning for ImagePullBackOff pods (${_ns_flag})..."

	local _images
	_images=$(oc get pods ${_ns_flag} -o json 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
seen = set()
for pod in data.get('items', []):
    all_cs = (pod.get('status', {}).get('containerStatuses', []) +
              pod.get('status', {}).get('initContainerStatuses', []))
    for cs in all_cs:
        reason = cs.get('state', {}).get('waiting', {}).get('reason', '')
        if reason in ('ImagePullBackOff', 'ErrImagePull'):
            img = cs.get('image', '')
            if img and img not in seen:
                seen.add(img)
                print(img)
" 2>/dev/null || true)

	if [[ -z "${_images}" ]]; then
		echo "      [repair] No ImagePullBackOff pods found."
		return 0
	fi

	local _repaired=0 _ok=0 _failed=0
	while IFS= read -r _img; do
		[[ -z "${_img}" ]] && continue

		# Map source image → bastion registry path
		local _local_path
		_local_path=$(python3 -c "
img = '${_img}'
nodigest = img.split('@')[0]
notag    = nodigest.split(':')[0]
parts    = notag.split('/')
# first component is a registry host if it contains '.' or ':'
path = '/'.join(parts[1:]) if ('.' in parts[0] or ':' in parts[0]) else notag
tag  = ':' + nodigest.split(':')[-1] if ':' in nodigest else ''
print('localhost:5000/' + path + tag)
" 2>/dev/null)

		echo "      [repair] ${_img}"
		if skopeo inspect --tls-verify=false --creds registry:registry \
				"docker://${_local_path}" &>/dev/null 2>&1; then
			echo "               → OK in registry"
			_ok=$(( _ok + 1 ))
			continue
		fi
		echo "               → CORRUPT/MISSING — repairing..."

		# Build digest-only source ref (skopeo rejects tag+digest combo)
		local _source_ref
		if [[ "${_img}" == *"@sha256:"* ]]; then
			local _digest="${_img##*@}"
			local _repo="${_img%%@*}"
			_source_ref="docker://${_repo%%:*}@${_digest}"
		else
			_source_ref="docker://${_img}"
		fi

		# Clear ALL stale _layers links for this repo so the registry accepts
		# fresh blob pushes. The missing blob is the config blob (a different hash
		# than the manifest-list digest), so clearing just the manifest hash is wrong.
		# Clearing all links is safe: actual blob data lives in the global blobs/sha256/
		# store; _layers links are just repository-scoped references that get re-created
		# on the next push.
		local _repo_name="${_local_path#localhost:5000/}"
		_repo_name="${_repo_name%%:*}"
		local _layers_dir="/opt/registry/data/docker/registry/v2/repositories/${_repo_name}/_layers/sha256"
		if [[ -d "${_layers_dir}" ]]; then
			rm -rf "${_layers_dir:?}"/*
			podman restart bastion-registry &>/dev/null && sleep 5 || true
		fi

		if skopeo copy --all \
				--insecure-policy \
				--authfile "${SCRIPT_DIR}/pull-secret.txt" \
				--src-tls-verify=false \
				--dest-tls-verify=false \
				--dest-creds registry:registry \
				--remove-signatures \
				"${_source_ref}" \
				"docker://${_local_path}" 2>&1 \
				| grep -E 'Copying config|Writing manifest|[Ee]rror' || true; then
			echo "               → Repaired"
			_repaired=$(( _repaired + 1 ))
		else
			echo "               → WARNING: repair failed"
			_failed=$(( _failed + 1 ))
		fi
	done <<< "${_images}"

	echo "      [repair] Done: ${_repaired} repaired, ${_ok} already OK, ${_failed} failed"
}

################################################################################
# Post-install step functions (8-11)
################################################################################

# Step 8: Mirror AWS S3 → bastion Minio using disconnected-s3
run_s3_mirror() {
	local _s3_dir="/tmp/disconnected-s3"
	local _minio_url="https://${BASTION_FQDN}:9000"

	[[ -n "${S3_REPO:-}" ]]              || die "S3 mirror requires --s3-repo <url> (disconnected-s3 is an internal GitLab repo)"
	[[ -n "${AWS_ACCESS_KEY_ID:-}" ]]    || die "S3 mirror requires AWS_ACCESS_KEY_ID (set in credentials.env)"
	[[ -n "${AWS_SECRET_ACCESS_KEY:-}" ]] || die "S3 mirror requires AWS_SECRET_ACCESS_KEY (set in credentials.env)"

	echo "==> [8] Mirror S3 config '${S3_MIRROR_CONFIG}' → Minio"
	if [[ -d "${_s3_dir}/.git" ]]; then
		git -C "${_s3_dir}" -c http.sslVerify=false pull --ff-only 2>/dev/null \
			|| echo "      WARNING: could not pull disconnected-s3, using cached clone"
	else
		echo "      Cloning disconnected-s3..."
		local _s3_repo_url
		if [[ -n "${GITLAB_TOKEN:-}" ]]; then
			_s3_repo_url="https://oauth2:${GITLAB_TOKEN}@${S3_REPO#https://}"
		else
			_s3_repo_url="${S3_REPO}"
			echo "      WARNING: GITLAB_TOKEN not set — clone may fail if repo is private"
		fi
		git -c http.sslVerify=false clone "${_s3_repo_url}" "${_s3_dir}"
	fi

	if ! command -v poetry &>/dev/null; then
		echo "      Installing poetry..."
		pip install poetry --quiet
		export PATH="${HOME}/.local/bin:${PATH}"
	fi

	if ! command -v python3.11 &>/dev/null; then
		echo "      Installing python3.11 (required by disconnected-s3)..."
		dnf install -y python3.11 --quiet
	fi

	cd "${_s3_dir}"
	poetry env use python3.11 --quiet 2>/dev/null || true
	poetry sync --quiet
	IFS=',' read -ra _cfgs <<< "${S3_MIRROR_CONFIG}"
	for _cfg in "${_cfgs[@]}"; do
		_cfg="${_cfg// /}"
		local _cfg_path="configs/${_cfg}.yaml"
		[[ -f "${_cfg_path}" ]] || die "S3 config file not found: ${_cfg_path} (check --s3-mirror-config)"
		echo "      s3-to-s3 config: ${_cfg}"
		poetry run python3 scripts/mirror.py s3-to-s3 \
			--source-endpoint "${AWS_S3_URL:-https://s3.amazonaws.com}" \
			--source-access-key "${AWS_ACCESS_KEY_ID}" \
			--source-secret-key "${AWS_SECRET_ACCESS_KEY}" \
			--target-endpoint "${_minio_url}" \
			--target-access-key "${MINIO_USERNAME:-minioadmin}" \
			--target-secret-key "${MINIO_PASSWORD:-minioadmin}" \
			--config "${_cfg_path}"
	done
	cd - > /dev/null
}

# Step 9: Install NFD + NVIDIA GPU operator via ods-ci gpu_deploy.sh
install_gpu_operator() {
	local _ods_ci_dir="/tmp/ods-ci"
	local _gpu_script="ods_ci/tasks/Resources/Provisioning/GPU/NVIDIA/gpu_deploy.sh"

	echo "==> [9] Install ${GPU_OPERATOR} GPU operator"
	[[ -f "${MNO_DIR}/kubeconfig" ]] \
		|| die "kubeconfig not found at ${MNO_DIR}/kubeconfig — deploy cluster first"

	if [[ ! -d "${_ods_ci_dir}/.git" ]]; then
		echo "      Cloning ods-ci..."
		GIT_TERMINAL_PROMPT=0 git clone --depth=1 -b "${ODS_CI_GIT_BRANCH}" \
			"${ODS_CI_GIT_REPO}" "${_ods_ci_dir}"
	fi
	[[ -f "${_ods_ci_dir}/${_gpu_script}" ]] \
		|| die "GPU deploy script not found: ${_ods_ci_dir}/${_gpu_script}"

	export KUBECONFIG="${MNO_DIR}/kubeconfig"
	export ENABLE_RDMA="${ENABLE_RDMA:-false}"

	echo "      Waiting for certified-operators CatalogSource to be ready..."
	local _deadline=$(( $(date +%s) + 300 ))
	until oc get packagemanifest gpu-operator-certified -n openshift-marketplace &>/dev/null; do
		[[ $(date +%s) -lt $_deadline ]] || die "Timed out waiting for gpu-operator-certified PackageManifest"
		sleep 10
	done
	echo "      gpu-operator-certified PackageManifest ready"

	# gpu_deploy.sh calls `tasks/Resources/.../install_nfd.sh` relative to CWD,
	# so we must run from the ods_ci/ subdirectory, not the repo root.
	cd "${_ods_ci_dir}/ods_ci"
	bash "tasks/Resources/Provisioning/GPU/NVIDIA/gpu_deploy.sh"
	cd - > /dev/null
}

# Step 10: Install full RHOAI 3.x stack via olminstall.
# Order mirrors Jenkins disconnectedCluster.installRHOAI() for the isRhoai3 branch.
install_rhoai() {
	local _olminstall_dir="/tmp/olminstall"
	local _catalog_source="${RHOAI_CATALOG_SOURCE:-rhoai-catalog-dev}"

	echo "==> [10] Install RHOAI channel=${RHOAI_UPDATE_CHANNEL} source=${_catalog_source}"
	[[ -f "${MNO_DIR}/kubeconfig" ]] \
		|| die "kubeconfig not found at ${MNO_DIR}/kubeconfig — deploy cluster first"

	if [[ -d "${_olminstall_dir}/.git" ]]; then
		git -C "${_olminstall_dir}" -c http.sslVerify=false pull --ff-only 2>/dev/null \
			|| echo "      WARNING: could not pull olminstall, using cached clone"
	else
		echo "      Cloning olminstall..."
		git -c http.sslVerify=false clone "${OLMINSTALL_REPO}" "${_olminstall_dir}"
	fi

	export KUBECONFIG="${MNO_DIR}/kubeconfig"
	export MIRROR_REGISTRY="${BASTION_FQDN}:5000"

	cd "${_olminstall_dir}"

	# Helper: give OLM time to create pods, then repair any corrupt blobs
	_install_op_with_repair() {
		./install-operator.sh "$@"
		sleep 20
		repair_pull_failures
	}

	_install_op_with_repair servicemeshoperator3
	_install_op_with_repair kueue-operator
	_install_op_with_repair leader-worker-set
	_install_op_with_repair jobset-operator
	_install_op_with_repair rhcl-operator
	_install_op_with_repair cert-manager-operator
	./configure-disconnected-rhcl.sh
	./configure-maas-gateway.sh
	./configure-llmd-gateway.sh
	./configure-maas-postgres.sh
	_install_op_with_repair custom-metrics-autoscaler
	_install_op_with_repair rhods-operator "${RHOAI_UPDATE_CHANNEL}" "${_catalog_source}"
	./create-dsc.sh
	./create-route.sh || true
	_install_op_with_repair mariadb-operator

	cd - > /dev/null
}

# Step 11: Append bastion CA certs to DSCI spec.trustedCABundle.customCABundle
add_custom_ca_bundles() {
	echo "==> [11] Add custom CA bundles to DSCI"
	[[ -f "${MNO_DIR}/kubeconfig" ]] \
		|| die "kubeconfig not found at ${MNO_DIR}/kubeconfig — deploy cluster first"
	export KUBECONFIG="${MNO_DIR}/kubeconfig"

	local _ca_paths=(
		"/opt/registry/certs/domain.crt"  # OCP image registry
		"/opt/minio/certs/public.crt"     # Minio (S3)
		"/opt/pypi-cache/devpi.crt"       # PyPI cache
		"/opt/git-cache/certs/git.crt"    # Git cache
	)
	for _cert in "${_ca_paths[@]}"; do
		[[ -f "${_cert}" ]] || { echo "      WARNING: ${_cert} not found — skipping"; continue; }

		local _new_bundle _existing _full_bundle _escaped _patch
		_new_bundle=$(cat "${_cert}")
		_existing=$(oc get dsci default-dsci \
			-o 'jsonpath={.spec.trustedCABundle.customCABundle}' 2>/dev/null || true)
		if [[ -n "${_existing}" ]]; then
			_full_bundle="${_existing}"$'\n'"${_new_bundle}"
		else
			_full_bundle="${_new_bundle}"
		fi
		_escaped=$(printf '%s' "${_full_bundle}" \
			| sed 's/\\/\\\\/g' \
			| sed ':a;N;$!ba;s/\n/\\n/g')
		_patch="[{\"op\":\"replace\",\"path\":\"/spec/trustedCABundle/customCABundle\",\"value\":\"${_escaped}\"}]"
		oc patch dsci default-dsci --type='json' -p="${_patch}"
		echo "      Added CA bundle: ${_cert}"
	done
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
