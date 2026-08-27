#!/usr/bin/env bash
# deploy_rhoai_bm.sh - End-to-end disconnected MNO + RHOAI deployment on Performance Lab bare metal
#
# Usage: ./deploy_rhoai_bm.sh <cloud-id> [OPTIONS]
#   e.g. ./deploy_rhoai_bm.sh cloud02
#        ./deploy_rhoai_bm.sh cloud02 --ocp-version latest-4.20 --rhoai-fbc-image quay.io/rhoai/...@sha256:...
#
# Assumes:
#   - ansible/vars/all.yml exists (copy from all.rhoai-disconnected-bm.sample.yml,
#     then set lab_cloud and worker_node_count)
#   - ansible/vars/sync-ocp-release.yml is configured
#   - ansible/vars/sync-operator-index.yml is populated by this script via --rhoai-fbc-image
#   - pull-secret.txt is present at the repo root
#   - Script is run from the repo root on the bastion machine

set -euo pipefail

# Resolve SCRIPT_DIR before sourcing utils so relative paths work correctly
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=deploy_rhoai_bm_utils.sh
source "${SCRIPT_DIR}/deploy_rhoai_bm_utils.sh"

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
# GITLAB_TOKEN must be set in the environment (via credentials.env) when cloning from
# gitlab.cee.redhat.com. Never pass it as a CLI flag to avoid shell history exposure.

# Post-install steps (8-11): all optional, controlled by flags below
GPU_OPERATOR=""                     # --gpu-operator nvidia
S3_MIRROR_CONFIG=""                 # --s3-mirror-config <config>[,<config>...]
S3_REPO=""                          # --s3-repo <url>  (disconnected-s3 clone URL)
RHOAI_UPDATE_CHANNEL=""             # --rhoai-update-channel beta|fast|stable-3.x
RHOAI_CATALOG_SOURCE="rhoai-catalog-dev"  # --rhoai-catalog-source
OLMINSTALL_REPO="https://gitlab.cee.redhat.com/data-hub/olminstall.git"
ODS_CI_GIT_REPO="https://github.com/red-hat-data-services/ods-ci.git"
ODS_CI_GIT_BRANCH="master"
ADD_CUSTOM_CA_BUNDLES=false         # --add-custom-ca-bundles
CLEANUP_RHOAI=false                 # --cleanup-rhoai
SKIP_IMAGE_REPAIR=false             # --skip-image-repair

# Well-known bastion paths (fixed for all MNO deployments)
MNO_DIR="/root/mno"
BASTION_CA_CERT="/opt/registry/certs/domain.crt"

MARKER_SYNC_OCP=".sync-ocp-done"
MARKER_SYNC_OP=".sync-operators-done"

LOGS_DIR="deploy-logs"

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
	--imageset-repo)        DISCONNECTED_IMAGESET_REPO="$2"; shift 2 ;;
	--nodes-override)       NODES_OVERRIDE="$2";            shift 2 ;;
	--refresh-nodes)        REFRESH_NODES=true;             shift ;;
	--resume)               RESUME=true;                    shift ;;
	--gpu-operator)         GPU_OPERATOR="$2";              shift 2 ;;
	--s3-mirror-config)     S3_MIRROR_CONFIG="$2";          shift 2 ;;
	--s3-repo)              S3_REPO="$2";                   shift 2 ;;
	--rhoai-update-channel) RHOAI_UPDATE_CHANNEL="$2";      shift 2 ;;
	--rhoai-catalog-source) RHOAI_CATALOG_SOURCE="$2";      shift 2 ;;
	--cluster-name)         CLUSTER_NAME="$2";              shift 2 ;;
	--olminstall-repo)      OLMINSTALL_REPO="$2";           shift 2 ;;
	--add-custom-ca-bundles) ADD_CUSTOM_CA_BUNDLES=true;    shift ;;
	--cleanup-rhoai)        CLEANUP_RHOAI=true;             shift ;;
	--skip-image-repair)    SKIP_IMAGE_REPAIR=true;         shift ;;
	-h|--help) usage ;;
	*) die "Unknown argument: $1" ;;
	esac
done

[[ -z "$CLOUD_ID" ]] && { echo "Error: cloud allocation id is required."; usage; }

################################################################################
# Pre-flight
################################################################################
cd "$SCRIPT_DIR"

# Ensure oc and other tools installed to /usr/local/bin are on PATH.
# The .ansible venv prepends its own bin but does not include /usr/local/bin.
export PATH="/usr/local/bin:${PATH}"

# Load credentials (GITLAB_TOKEN, AWS_*, etc.) from gitignored file if present.
# Source before the exec tee redirect so credentials are never echoed to the log.
[[ -f "${SCRIPT_DIR}/credentials.env" ]] && source "${SCRIPT_DIR}/credentials.env"

[[ -f "$ALL_VARS" ]] || die "$(printf '%s\n%s\n%s' \
	"ansible/vars/all.yml not found." \
	"Create it from the RHOAI disconnected BM template:" \
	"  cp ansible/vars/all.rhoai-disconnected-bm.sample.yml ansible/vars/all.yml")"

# Auto-create gitignored vars files from their samples on first run.
# patch_yaml_scalar / patch_rhoai_vars modify these files; they must exist first.
for _pair in \
	"sync-ocp-release.sample.yml:${SYNC_OCP_VARS}" \
	"sync-operator-index.sample.yml:${SYNC_OP_VARS}"; do
	_sample="ansible/vars/${_pair%%:*}"
	_target="${_pair##*:}"
	if [[ ! -f "${_target}" ]]; then
		cp "${_sample}" "${_target}"
		echo "      Created ${_target} from sample (first run)"
	fi
done

INVENTORY="ansible/inventory/${CLOUD_ID}.local"
BASTION_FQDN="$(hostname -f)"

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

	# Apply any manual --rhoai-* flag overrides (channel, version, catalog).
	# populate_rhoai_images() runs after step 3 so skopeo + Go yq are available.
	[[ -n "$RHOAI_CATALOG" || -n "$RHOAI_FBC_IMAGE" || -n "$RHOAI_VERSION" || -n "$RHOAI_CHANNEL" ]] \
		&& patch_rhoai_vars

	[[ -n "$NODES_OVERRIDE" ]] && patch_nodes_override "$NODES_OVERRIDE"

	ansible-playbook ansible/create-inventory.yml -e "cluster_name=${CLUSTER_NAME:-llmd}"
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
# populate_rhoai_images() runs here (after step 3) so skopeo and Go yq are
# guaranteed to be installed by bastion-install before generate.sh is called.
################################################################################
if [[ -n "${RHOAI_FBC_IMAGE}" ]]; then
	populate_rhoai_images
	# patch_rhoai_vars must run AFTER populate_rhoai_images so RHOAI_CATALOG/VERSION/CHANNEL
	# are derived from the inspected FBC image before being written to sync-operator-index.yml.
	# (Step 2 calls it earlier but RHOAI_CATALOG is empty then if --rhoai-catalog wasn't passed.)
	patch_rhoai_vars

	# Mirror failures tolerated by the sync playbook (see J-20 in jetlag_todos.md
	# for the full impact assessment). "Allowed" means: cannot be fixed by
	# re-running the mirror, and must not block cluster deployment — NOT that the
	# images are unneeded:
	# - rhaii/vllm-*: bundle references digests deleted upstream (FBC defect —
	#   would fail on connected clusters too; llm-d tests use their own vllm images)
	# - odh-operator-bundle: knock-on skip; validated later by 7c rhods CSV check
	# - nvidia/gpu-operator-bundle: missing upstream .sig; validated later by 7b —
	#   if 7b fails, mirror it manually with --remove-signatures
	# - mariadb / context deadline exceeded / unexpected EOF: transient network
	#   blips reading large blobs from upstream CDNs; complete on later re-runs
	# - openshift-serverless-1/serverless-operator-bundle: knock-on skip when its
	#   related kn-serving-autoscaler-hpa-rhel9 image hits a transient EOF above;
	#   validated later — if serverless-operator install/use breaks, mirror the
	#   bundle + kn-serving-autoscaler-hpa-rhel9 manually and re-run step 5
	"${GO_YQ}" e -i '.allowed_mirror_failure_patterns = [
		"registry\.redhat\.io/rhaii/vllm-",
		"rhoai/odh-operator-bundle",
		"nvidia/gpu-operator-bundle",
		"docker-registry1\.mariadb\.com",
		"context deadline exceeded",
		"unexpected EOF",
		"openshift-serverless-1/serverless-operator-bundle"
	]' "${SYNC_OP_VARS}"

	# mno-deploy.yml (step 6) loads only all.yml, so mirror operator_index_name
	# there too — otherwise mno-post-cluster-install falls back to the role
	# default (redhat-operator-index) and applies cluster-resources from a
	# working-dir that does not exist.
	_op_idx=$(grep -m1 '^operator_index_name:' "${SYNC_OP_VARS}" | awk '{print $2}' | tr -d '"')
	[[ -n "${_op_idx}" ]] && patch_yaml_scalar "$ALL_VARS" "operator_index_name" "${_op_idx}"
fi

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

# OpenShift additionalTrustedCA key format: <hostname>..<port> with dots in hostname
# replaced by .. (double-dot) per OCP convention, e.g. foo..bar..example..com..5000
_registry_key="${BASTION_FQDN//./'..'}..5000"
if [[ -f "${BASTION_CA_CERT}" ]]; then
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
		sed 's/^/    /' "${BASTION_CA_CERT}"
	} > "${MNO_DIR}/registry-ca-configmap.yaml"

	cat > "${MNO_DIR}/image-config-patch.yaml" <<'YAML'
spec:
  additionalTrustedCA:
    name: bastion-registry-ca
YAML
	echo "      Registry CA manifests → ${MNO_DIR}/registry-ca-configmap.yaml"
	echo "      Image config patch    → ${MNO_DIR}/image-config-patch.yaml"

	# Apply immediately so nodes trust the registry before operator installs.
	# Idempotent: oc apply is safe to run on every resume.
	if [[ -f "${MNO_DIR}/kubeconfig" ]]; then
		export KUBECONFIG="${MNO_DIR}/kubeconfig"
		oc apply -f "${MNO_DIR}/registry-ca-configmap.yaml" 2>&1 | sed 's/^/      /'
		oc patch image.config.openshift.io/cluster --type=merge \
			--patch-file "${MNO_DIR}/image-config-patch.yaml" 2>&1 | sed 's/^/      /'
	fi
else
	echo "      WARNING: ${BASTION_CA_CERT} not found — registry CA manifests not generated"
fi

# Emit cluster-info.env — stable interface for Jenkins and external consumers
_cluster_name=$(grep -m1 'cluster_name=' "${INVENTORY}" 2>/dev/null | cut -d= -f2 || echo "${CLUSTER_NAME:-llmd}")
_base_dns_name=$(grep -m1 'base_dns_name=' "${INVENTORY}" 2>/dev/null | cut -d= -f2 || echo "")
cat > "${MNO_DIR}/cluster-info.env" <<ENV
CLUSTER_API_URL=https://${BASTION_FQDN}:6443
CLUSTER_APPS_DOMAIN=apps.${_cluster_name}.${_base_dns_name}
BASTION_FQDN=${BASTION_FQDN}
KUBECONFIG_PATH=${MNO_DIR}/kubeconfig
JENKINS_KUBECONFIG_PATH=${MNO_DIR}/jenkins-kubeconfig
KUBEADMIN_PASSWORD_PATH=${MNO_DIR}/kubeadmin-password
RHOAI_FBC_IMAGE=${RHOAI_FBC_IMAGE:-}
ENV
echo "      Cluster info env     → ${MNO_DIR}/cluster-info.env"

# ${MNO_DIR}/kubeconfig stays untouched (system:admin client-cert, internal API
# URL) for Jetlag's own post-install steps and local QE cluster administration
# on the bastion. Jenkins gets a dedicated derived copy instead, refreshed on
# every run so its bearer token never outlives a single deploy/resume pass.
cp -f "${MNO_DIR}/kubeconfig" "${MNO_DIR}/jenkins-kubeconfig"

# For enabling Jenkins to authenticate directly against the API server, bake a
# bearer token (minted via internal API login) into the Jenkins kubeconfig.
patch_jenkins_kubeconfig_token

# Patch Jenkins kubeconfig server: to bastion FQDN so Jenkins can use it directly.
patch_jenkins_kubeconfig_server

# Deploy Squid proxy on port 3128 and append proxy vars to cluster-info.env.
setup_bastion_proxy

################################################################################
# Step 7: Apply IDMS/ITMS/CatalogSources + MCP rollout
################################################################################
if ! should_skip "7" "Apply mirror manifests, CatalogSources and MCP rollout"; then
	echo "==> [7] Apply mirror manifests, CatalogSources and MCP rollout"

	_op_idx_name=$(grep -m1 '^operator_index_name:' "$SYNC_OP_VARS" 2>/dev/null \
		| awk '{print $2}' | tr -d '"' || true)
	_op_idx_name="${_op_idx_name:-redhat-operator-index}"
	_cluster_resources="/opt/registry/sync/operators/${_op_idx_name}/working-dir/cluster-resources"

	if [[ -f "${MNO_DIR}/kubeconfig" && -d "${_cluster_resources}" ]]; then
		export KUBECONFIG="${MNO_DIR}/kubeconfig"
		_changed=0
		for _f in idms-oc-mirror.yaml itms-oc-mirror.yaml catalog-sources.yaml; do
			if [[ -f "${_cluster_resources}/${_f}" ]]; then
				_out=$(oc apply -f "${_cluster_resources}/${_f}" 2>&1)
				echo "${_out}"
				echo "${_out}" | grep -qE ' (created|configured)$' && _changed=1 || true
			fi
		done
		if [[ "${_changed}" -eq 1 ]]; then
			echo "      Waiting for MachineConfigPool rollout..."
			oc wait mcp master worker --for condition=updated --timeout=600s || \
				echo "      WARNING: MCP did not reach Updated within 600s — check 'oc get mcp'"
		else
			echo "      No manifest changes — skipping MCP rollout wait"
		fi

		# R-3: Create rhoai-catalog-dev CatalogSource alias.
		# oc-mirror generates the CatalogSource name from target_catalog (replace '/' with '-'),
		# producing e.g. 'rhoai-rhoai-operator-index'. olminstall hardcodes source: rhoai-catalog-dev
		# in all RHOAI Subscription templates, so we create the alias here.
		if [[ -n "${RHOAI_UPDATE_CHANNEL}${RHOAI_FBC_IMAGE}" ]]; then
			if oc get catalogsource rhoai-catalog-dev -n openshift-marketplace &>/dev/null 2>&1; then
				echo "      rhoai-catalog-dev CatalogSource already exists"
			else
				_cs_yaml="${_cluster_resources}/catalog-sources.yaml"
				_cs_image=""
				if [[ -f "${_cs_yaml}" ]]; then
					_cs_image=$("${GO_YQ}" e \
						'select(.metadata.name | test("rhoai")) | .spec.image' \
						"${_cs_yaml}" 2>/dev/null | head -1 || true)
				fi
				if [[ -z "${_cs_image}" ]]; then
					_rhoai_target=$(yq -r '.catalogs_to_sync[0].target_catalog // "rhoai/rhoai-operator-index"' \
						"${SYNC_OP_VARS}" 2>/dev/null || echo "rhoai/rhoai-operator-index")
					_rhoai_tag=$(grep -m1 '^operator_index_tag:' "${SYNC_OP_VARS}" 2>/dev/null \
						| awk '{print $2}' | tr -d '"' || echo "v4.20")
					_cs_image="${BASTION_FQDN}:5000/${_rhoai_target}:${_rhoai_tag}"
				fi
				echo "      Creating rhoai-catalog-dev CatalogSource → ${_cs_image}"
				oc apply -f - <<YAML
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: rhoai-catalog-dev
  namespace: openshift-marketplace
spec:
  sourceType: grpc
  image: ${_cs_image}
  displayName: RHOAI Catalog Dev
  publisher: Red Hat
YAML
			fi
		fi
	else
		[[ ! -f "${MNO_DIR}/kubeconfig" ]] && \
			echo "      Skipping — kubeconfig not found (cluster not yet deployed)" || true
		[[ ! -d "${_cluster_resources}" ]] && \
			echo "      Skipping — ${_cluster_resources} not found (run Step 5 first)" || true
	fi
fi

################################################################################
# Steps 8-11: optional post-install steps
################################################################################

# 8: S3 → Minio mirror (always re-run when flag set; s3-to-s3 is idempotent)
[[ -n "${S3_MIRROR_CONFIG}" ]] && run_s3_mirror

# Pre-step bulk repair: proactively fix all oc-mirror v2 corrupt blobs in the
# bastion registry before any operator install. Runs once here — covers both
# the GPU operator and the full RHOAI olminstall stack.
export KUBECONFIG="${MNO_DIR}/kubeconfig"
${SKIP_IMAGE_REPAIR} || preflight_repair_registry

# 9: GPU operator install
if [[ "${GPU_OPERATOR,,}" == "nvidia" ]]; then
	if ! should_skip 9 "GPU operator (${GPU_OPERATOR})"; then
		install_gpu_operator
	fi
fi

# 10: RHOAI install via olminstall
if [[ -n "${RHOAI_UPDATE_CHANNEL}" ]]; then
	${CLEANUP_RHOAI} && cleanup_rhoai
	if ! should_skip 10 "RHOAI install (channel=${RHOAI_UPDATE_CHANNEL})"; then
		install_rhoai
	fi
fi

# 11: DSCI custom CA bundles
if ${ADD_CUSTOM_CA_BUNDLES}; then
	if ! should_skip 11 "DSCI custom CA bundles"; then
		add_custom_ca_bundles
	fi
fi

echo ""
echo "Deployment complete. Access the cluster from the bastion:"
echo "  export KUBECONFIG=${MNO_DIR}/kubeconfig"
echo "  oc get nodes"
echo "  cat ${MNO_DIR}/kubeadmin-password"
echo ""
echo "Apply registry CA trust (required before installing RHOAI):"
echo "  oc apply -f ${MNO_DIR}/registry-ca-configmap.yaml"
echo "  oc patch image.config.openshift.io/cluster --type=merge --patch-file ${MNO_DIR}/image-config-patch.yaml"
