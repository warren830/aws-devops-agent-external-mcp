#!/usr/bin/env bash
# L8 recover: restore ALB target-group health-check-interval to 30s and
# force a deployment re-roll to refresh pods.
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
TARGET_INTERVAL=30
TG_FILE="${FAULT_METADATA_DIR}/L8-target-group-arn.txt"

log_step "L8 RECOVER - HC interval -> ${TARGET_INTERVAL}s + deployment re-roll"

validate_profile "$PROFILE" "" "$REGION"

# Resolve TG ARN: env > metadata file > rediscovery.
TG_ARN="${BJS_ALB_TG_ARN:-}"
if [[ -z "$TG_ARN" && -f "$TG_FILE" ]]; then
    TG_ARN=$(cat "$TG_FILE")
fi

if [[ -z "$TG_ARN" ]]; then
    log_info "TG ARN not cached - rediscovering ALB '${ALB_NAME}'..."
    lb_arn=$(aws elbv2 describe-load-balancers \
        --names "$ALB_NAME" \
        --profile "$PROFILE" --region "$REGION" \
        --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || echo "")
    if [[ -z "$lb_arn" || "$lb_arn" == "None" ]]; then
        lb_arn=$(aws elbv2 describe-load-balancers \
            --profile "$PROFILE" --region "$REGION" \
            --query "LoadBalancers[?contains(LoadBalancerName, 'bjs-web')].LoadBalancerArn | [0]" \
            --output text 2>/dev/null || echo "")
    fi
    if [[ -z "$lb_arn" || "$lb_arn" == "None" ]]; then
        log_warn "Could not find ALB - skipping HC interval recover."
        TG_ARN=""
    else
        TG_ARN=$(aws elbv2 describe-target-groups \
            --load-balancer-arn "$lb_arn" \
            --profile "$PROFILE" --region "$REGION" \
            --query 'TargetGroups[0].TargetGroupArn' --output text)
    fi
fi

if [[ -n "$TG_ARN" && "$TG_ARN" != "None" ]]; then
    current=$(aws elbv2 describe-target-groups \
        --target-group-arns "$TG_ARN" \
        --profile "$PROFILE" --region "$REGION" \
        --query 'TargetGroups[0].HealthCheckIntervalSeconds' --output text)
    log_info "Current interval: ${current}s"

    if [[ "$current" == "$TARGET_INTERVAL" ]]; then
        log_ok "Already at ${TARGET_INTERVAL}s"
    else
        log_action "Setting interval ${current}s -> ${TARGET_INTERVAL}s"
        aws elbv2 modify-target-group \
            --target-group-arn "$TG_ARN" \
            --health-check-interval-seconds "$TARGET_INTERVAL" \
            --healthy-threshold-count 2 \
            --unhealthy-threshold-count 2 \
            --profile "$PROFILE" --region "$REGION" \
            --no-cli-pager >/dev/null
        log_ok "HC interval restored to ${TARGET_INTERVAL}s"
    fi
fi

[[ -f "$TG_FILE" ]] && rm -f "$TG_FILE"

# Force re-roll.
if command -v kubectl >/dev/null 2>&1 && \
   kubectl config get-contexts -o name | grep -q "^${CONTEXT}$"; then
    log_action "Forcing rollout restart of ${DEPLOY}"
    kubectl --context "$CONTEXT" -n "$NS" rollout restart "deployment/${DEPLOY}" || \
        log_warn "rollout restart failed - continuing"
    log_ok "Re-roll triggered"
else
    log_warn "kubectl context '${CONTEXT}' not configured - skipping re-roll"
fi

log_ok "L8 recover complete."
