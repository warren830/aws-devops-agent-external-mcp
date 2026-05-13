#!/usr/bin/env bash
# L6 inject: set bjs1 todo-api deployment image to a non-existent tag,
# producing ImagePullBackOff. Drives Case C1 (Webhook autonomous triage).
unset AWS_PROFILE AWS_REGION
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

trap 'on_error $LINENO' ERR
parse_debug_flag "$@"

CONTEXT="$FAULT_BJS1_EKS_CTX"
NS="$FAULT_BJS1_NS"
DEPLOY="$FAULT_BJS1_DEPLOY"
CONTAINER="$FAULT_BJS1_CONTAINER"
BAD_TAG="$FAULT_BJS1_BAD_TAG"

log_step "L6 INJECT - set ${DEPLOY} image to invalid tag (${BAD_TAG})"

# Check kubectl context exists.
if ! command -v kubectl >/dev/null 2>&1; then
    log_err "kubectl not found in PATH"
    exit 1
fi

if ! kubectl config get-contexts -o name | grep -q "^${CONTEXT}$"; then
    log_err "kubectl context '${CONTEXT}' not configured."
    log_err "Available contexts:"
    kubectl config get-contexts -o name >&2 || true
    log_err "Configure with: aws eks --profile ${FAULT_BJS1_PROFILE} --region ${FAULT_BJS1_REGION} update-kubeconfig --name bjs-web --alias ${CONTEXT}"
    exit 1
fi

# Determine the ECR registry from the *current* image (so we don't have to hardcode).
log_info "Reading current image for ${DEPLOY}.${CONTAINER}..."
current_image=$(kubectl --context "$CONTEXT" -n "$NS" \
    get deployment "$DEPLOY" \
    -o jsonpath="{.spec.template.spec.containers[?(@.name=='${CONTAINER}')].image}" 2>&1) || {
    log_err "kubectl get deployment failed: $current_image"
    exit 1
}

if [[ -z "$current_image" ]]; then
    log_err "Could not read current image - is the deployment present?"
    exit 1
fi
log_info "Current image: ${current_image}"

# Build the new (broken) image string. Strip existing tag, append BAD_TAG.
image_repo="${current_image%:*}"
new_image="${image_repo}:${BAD_TAG}"
log_action "Will set image: ${current_image} -> ${new_image}"

if ! confirm "Apply broken image '${new_image}' to ${DEPLOY}?"; then
    log_warn "User declined - aborting."
    exit 1
fi

kubectl --context "$CONTEXT" -n "$NS" \
    set image "deployment/${DEPLOY}" "${CONTAINER}=${new_image}"

# Record the pre-injection image so recover can use it if no good tag is set.
echo "$current_image" >"${FAULT_METADATA_DIR}/L6-previous-image.txt"

log_ok "L6 injected. New pods will fail with ImagePullBackOff in ~30-60s."
log_info "Watch with: kubectl --context ${CONTEXT} -n ${NS} get pods -w"
