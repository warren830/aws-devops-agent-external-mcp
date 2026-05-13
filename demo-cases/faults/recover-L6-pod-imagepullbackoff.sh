#!/usr/bin/env bash
# L6 recover: roll back ${DEPLOY} to a known good image tag.
#
# Resolution order for the good tag:
#   1. CLI arg $1
#   2. env FAULT_BJS1_GOOD_TAG (defaulted in common.sh)
#   3. content of L6-previous-image.txt written by inject (full image string)
#
# Idempotent.
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
GOOD_TAG="${1:-$FAULT_BJS1_GOOD_TAG}"
PREV_FILE="${FAULT_METADATA_DIR}/L6-previous-image.txt"

log_step "L6 RECOVER - roll ${DEPLOY} back to ${GOOD_TAG}"

if ! command -v kubectl >/dev/null 2>&1; then
    log_err "kubectl not found"
    exit 1
fi

if ! kubectl config get-contexts -o name | grep -q "^${CONTEXT}$"; then
    log_err "kubectl context '${CONTEXT}' not configured"
    exit 1
fi

current_image=$(kubectl --context "$CONTEXT" -n "$NS" \
    get deployment "$DEPLOY" \
    -o jsonpath="{.spec.template.spec.containers[?(@.name=='${CONTAINER}')].image}" 2>/dev/null || echo "")

if [[ -z "$current_image" ]]; then
    log_err "Could not read current image"
    exit 1
fi
log_info "Current image: ${current_image}"

# Decide target.
if [[ -n "${1:-}" ]]; then
    image_repo="${current_image%:*}"
    new_image="${image_repo}:${GOOD_TAG}"
elif [[ -f "$PREV_FILE" ]]; then
    new_image=$(cat "$PREV_FILE")
    log_info "Using previous image from ${PREV_FILE}: ${new_image}"
else
    image_repo="${current_image%:*}"
    new_image="${image_repo}:${GOOD_TAG}"
fi

if [[ "$current_image" == "$new_image" ]]; then
    log_ok "Already at target image ${new_image} - nothing to do."
    exit 0
fi

log_action "Will set image: ${current_image} -> ${new_image}"
kubectl --context "$CONTEXT" -n "$NS" \
    set image "deployment/${DEPLOY}" "${CONTAINER}=${new_image}"

[[ -f "$PREV_FILE" ]] && rm -f "$PREV_FILE"

log_ok "L6 recovered. New pods rolling out."
log_info "Verify: kubectl --context ${CONTEXT} -n ${NS} rollout status deployment/${DEPLOY}"
