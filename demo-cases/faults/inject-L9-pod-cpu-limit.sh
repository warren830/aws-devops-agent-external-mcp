#!/usr/bin/env bash
# L9 inject: patch todo-api pod CPU limit down to 100m to cause throttling.
# Drives Case C9 (multi-source RCA, CPU throttle as secondary root cause).
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
TARGET_CPU="100m"

log_step "L9 INJECT - patch ${DEPLOY} CPU limit -> ${TARGET_CPU}"

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
    log_ok "Already at ${TARGET_CPU} - skipping."
    exit 0
fi

log_action "Will patch CPU limit ${current:-<unset>} -> ${TARGET_CPU}"
if ! confirm "Apply CPU limit ${TARGET_CPU}?"; then
    log_warn "User declined - aborting."
    exit 1
fi

patch_json=$(printf '{"spec":{"template":{"spec":{"containers":[{"name":"%s","resources":{"limits":{"cpu":"%s"}}}]}}}}' \
    "$CONTAINER" "$TARGET_CPU")

kubectl --context "$CONTEXT" -n "$NS" \
    patch "deployment/${DEPLOY}" \
    --patch "$patch_json"

log_ok "L9 injected. CPU throttling should appear in Container Insights."
