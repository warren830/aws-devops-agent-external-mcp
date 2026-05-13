#!/usr/bin/env bash
# L8 inject: set ALB target group health-check-interval to 240s on bjs-web ALB,
# then delete one EKS pod to surface unhealthy state. Drives Case C4 (blast radius).
unset AWS_PROFILE AWS_REGION
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

trap 'on_error $LINENO' ERR
parse_debug_flag "$@"

PROFILE="$FAULT_BJS1_PROFILE"
REGION="$FAULT_BJS1_REGION"
ALB_NAME="$FAULT_BJS1_ALB_NAME"
CONTEXT="$FAULT_BJS1_EKS_CTX"
NS="$FAULT_BJS1_NS"
DEPLOY="$FAULT_BJS1_DEPLOY"
TARGET_INTERVAL=240

log_step "L8 INJECT - ALB target-group health-check-interval=${TARGET_INTERVAL}s + delete one pod"

validate_profile "$PROFILE" "" "$REGION"

# Discover the ALB ARN. We allow override via env BJS_ALB_TG_ARN.
TG_ARN="${BJS_ALB_TG_ARN:-}"
if [[ -z "$TG_ARN" ]]; then
    log_info "Discovering ALB '${ALB_NAME}' and its target group..."

    # First try LB by name; fall back to substring search.
    lb_arn=$(aws elbv2 describe-load-balancers \
        --names "$ALB_NAME" \
        --profile "$PROFILE" --region "$REGION" \
        --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || echo "")

    if [[ -z "$lb_arn" || "$lb_arn" == "None" ]]; then
        log_info "No exact match - searching by substring 'bjs-web'..."
        lb_arn=$(aws elbv2 describe-load-balancers \
            --profile "$PROFILE" --region "$REGION" \
            --query "LoadBalancers[?contains(LoadBalancerName, 'bjs-web')].LoadBalancerArn | [0]" \
            --output text 2>/dev/null || echo "")
    fi

    if [[ -z "$lb_arn" || "$lb_arn" == "None" ]]; then
        log_err "Could not find ALB. Set BJS_ALB_TG_ARN env var explicitly."
        exit 1
    fi
    log_info "ALB ARN: ${lb_arn}"

    TG_ARN=$(aws elbv2 describe-target-groups \
        --load-balancer-arn "$lb_arn" \
        --profile "$PROFILE" --region "$REGION" \
        --query 'TargetGroups[0].TargetGroupArn' --output text)

    if [[ -z "$TG_ARN" || "$TG_ARN" == "None" ]]; then
        log_err "No target groups attached to ALB ${lb_arn}"
        exit 1
    fi
fi
log_info "Target group ARN: ${TG_ARN}"

# Read current interval.
current=$(aws elbv2 describe-target-groups \
    --target-group-arns "$TG_ARN" \
    --profile "$PROFILE" --region "$REGION" \
    --query 'TargetGroups[0].HealthCheckIntervalSeconds' --output text)
log_info "Current health-check-interval: ${current}s"

if [[ "$current" == "$TARGET_INTERVAL" ]]; then
    log_ok "Already at ${TARGET_INTERVAL}s - skipping interval change."
else
    log_action "Setting health-check-interval ${current}s -> ${TARGET_INTERVAL}s"
    if ! confirm "Apply HC interval change to TG?"; then
        log_warn "User declined - aborting."
        exit 1
    fi
    # ALB requires unhealthy threshold * interval >= deregistration delay; we
    # set unhealthy threshold to 2 to keep the math simple.
    aws elbv2 modify-target-group \
        --target-group-arn "$TG_ARN" \
        --health-check-interval-seconds "$TARGET_INTERVAL" \
        --healthy-threshold-count 2 \
        --unhealthy-threshold-count 2 \
        --profile "$PROFILE" --region "$REGION" \
        --no-cli-pager >/dev/null
    log_ok "Interval set to ${TARGET_INTERVAL}s"
fi

echo "$TG_ARN" >"${FAULT_METADATA_DIR}/L8-target-group-arn.txt"

# Delete one pod to force unhealthy state.
if command -v kubectl >/dev/null 2>&1 && \
   kubectl config get-contexts -o name | grep -q "^${CONTEXT}$"; then
    log_action "Deleting one ${DEPLOY} pod to surface unhealthy state"
    pod=$(kubectl --context "$CONTEXT" -n "$NS" \
        get pods -l "app=${DEPLOY}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [[ -z "$pod" ]]; then
        # Try without label filter.
        pod=$(kubectl --context "$CONTEXT" -n "$NS" \
            get pods -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    fi
    if [[ -n "$pod" ]]; then
        kubectl --context "$CONTEXT" -n "$NS" delete pod "$pod" --wait=false || \
            log_warn "Pod delete failed - continuing anyway."
        log_ok "Deleted pod ${pod}"
    else
        log_warn "Could not find a pod to delete - skipping (TG interval is still set)."
    fi
else
    log_warn "kubectl context '${CONTEXT}' not configured - skipping pod delete."
fi

log_ok "L8 inject complete."
