#!/usr/bin/env bash
# L5 recover: scale ECS back to 1, switch DDB back to PAY_PER_REQUEST,
# drain the SQS queue. Idempotent.
unset AWS_PROFILE AWS_REGION
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

trap 'on_error $LINENO' ERR
parse_debug_flag "$@"

PROFILE="$FAULT_CHINA_PROFILE"
REGION="$FAULT_CHINA_REGION"
CLUSTER="$FAULT_CHINA_ECS_CLUSTER"
SERVICE="$FAULT_CHINA_ECS_ETL_SERVICE"
DDB_TABLE="$FAULT_CHINA_DDB_TABLE"
SQS_NAME="$FAULT_CHINA_SQS_NAME"
TARGET_COUNT=1

log_step "L5 RECOVER - scale down + DDB to on-demand + drain SQS"

validate_profile "$PROFILE" "" "$REGION"

# Scale ECS back to 1.
current_count=$(aws ecs describe-services \
    --cluster "$CLUSTER" --services "$SERVICE" \
    --profile "$PROFILE" --region "$REGION" \
    --query 'services[0].desiredCount' --output text 2>/dev/null || echo "MISSING")

if [[ "$current_count" == "MISSING" ]]; then
    log_warn "ECS service not found - skipping scale step."
elif [[ "$current_count" == "$TARGET_COUNT" ]]; then
    log_ok "ECS already at ${TARGET_COUNT}"
else
    log_action "Scaling ${SERVICE} -> ${TARGET_COUNT}"
    aws ecs update-service \
        --cluster "$CLUSTER" --service "$SERVICE" \
        --desired-count "$TARGET_COUNT" \
        --profile "$PROFILE" --region "$REGION" \
        --no-cli-pager >/dev/null
    log_ok "ECS scaled to ${TARGET_COUNT}"
fi

# DDB back to PAY_PER_REQUEST.
billing=$(aws dynamodb describe-table \
    --table-name "$DDB_TABLE" \
    --profile "$PROFILE" --region "$REGION" \
    --query 'Table.BillingModeSummary.BillingMode' --output text 2>/dev/null || echo "MISSING")

if [[ "$billing" == "MISSING" ]]; then
    log_warn "DDB table missing - skipping."
elif [[ "$billing" == "PAY_PER_REQUEST" ]]; then
    log_ok "DDB already PAY_PER_REQUEST"
else
    log_action "Switching ${DDB_TABLE} to PAY_PER_REQUEST"
    aws dynamodb update-table \
        --table-name "$DDB_TABLE" \
        --billing-mode PAY_PER_REQUEST \
        --profile "$PROFILE" --region "$REGION" \
        --no-cli-pager >/dev/null
    log_ok "DDB switched to PAY_PER_REQUEST"
fi

# Drain SQS queue.
queue_url=$(aws sqs get-queue-url \
    --queue-name "$SQS_NAME" \
    --profile "$PROFILE" --region "$REGION" \
    --query 'QueueUrl' --output text 2>/dev/null || echo "")

if [[ -z "$queue_url" || "$queue_url" == "None" ]]; then
    log_warn "SQS queue ${SQS_NAME} not found - skipping drain."
else
    log_action "Purging SQS queue ${queue_url}"
    # purge-queue can be called once per 60s; ignore failures.
    if aws sqs purge-queue \
            --queue-url "$queue_url" \
            --profile "$PROFILE" --region "$REGION" \
            --no-cli-pager 2>/dev/null; then
        log_ok "SQS queue purged"
    else
        log_warn "SQS purge failed (rate-limited - 1/min). Try again in 60s if needed."
    fi
fi

log_ok "L5 recover complete."
