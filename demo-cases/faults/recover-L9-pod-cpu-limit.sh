#!/usr/bin/env bash
# L9 recover: patch CPU limit back to 500m. Idempotent.
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
TARGET_CPU="${L9_GOOD_CPU:-500m}"

log_step "L9 RECOVER - patch ${DEPLOY} CPU limit -> ${TARGET_CPU}"

if ! command -v kubectl >/dev/null 2>&1; then
    log_err "kubectl not found"
    exit 1
fi

if ! kubectl config get-contexts -o name | grep -q "^${CONTEXT}$"; then
    log_err "kubectl context '${CONTEXT}' not configured"
    exit 1
fi

current=$(kubectl --context "$CONTEXT" -n "$NS" \
    get deployment "$DEPLOY" \
    -o jsonpath="{.spec.template.spec.containers[?(@.name=='${CONTAINER}')].resources.limits.cpu}" 2>/dev/null || echo "")
log_info "Current CPU limit: '${current:-<unset>}'"

if [[ "$current" == "$TARGET_CPU" ]]; then
    log_ok "Already at ${TARGET_CPU} - nothing to do."
    exit 0
fi

log_action "Patching CPU limit -> ${TARGET_CPU}"
patch_json=$(printf '{"spec":{"template":{"spec":{"containers":[{"name":"%s","resources":{"limits":{"cpu":"%s"}}}]}}}}' \
    "$CONTAINER" "$TARGET_CPU")

kubectl --context "$CONTEXT" -n "$NS" \
    patch "deployment/${DEPLOY}" \
    --patch "$patch_json"

log_ok "L9 recovered. CPU limit set to ${TARGET_CPU}."
