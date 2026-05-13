#!/usr/bin/env bash
# L5 inject: china etl-worker OOM + DynamoDB throttle (drives Case C3).
# Steps:
#   (a) Verify (or set) etl-worker task-definition memory = 256 MB
#   (b) Switch DynamoDB etl-state to PROVISIONED 5/5
#   (c) Invoke etl-trigger Lambda to push 100 items into SQS
#   (d) Scale ECS service desired-count to 5
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
LAMBDA_NAME="$FAULT_CHINA_LAMBDA_TRIGGER"
TARGET_COUNT=5

log_step "L5 INJECT - china ETL OOM + DDB throttle"

validate_profile "$PROFILE" "" "$REGION"

# (a) Inspect task definition memory.
log_info "Inspecting task definition memory for ${SERVICE}..."
task_def_arn=$(aws ecs describe-services \
    --cluster "$CLUSTER" --services "$SERVICE" \
    --profile "$PROFILE" --region "$REGION" \
    --query 'services[0].taskDefinition' --output text)
log_info "Active task definition: ${task_def_arn}"

memory=$(aws ecs describe-task-definition \
    --task-definition "$task_def_arn" \
    --profile "$PROFILE" --region "$REGION" \
    --query 'taskDefinition.memory' --output text 2>/dev/null || echo "")

if [[ "$memory" != "256" && "$memory" != "256MiB" ]]; then
    log_warn "Task def memory is '${memory}', not 256. The L5 fault assumes the"
    log_warn "infra-baked task def is already 256 MB. If your infra has been changed,"
    log_warn "manually re-register a 256-MB revision before continuing."
else
    log_ok "Task def memory = 256 MB (matches L5 baseline)"
fi

# (b) Switch DynamoDB to PROVISIONED 5/5.
log_info "Reading current billing mode for ${DDB_TABLE}..."
billing=$(aws dynamodb describe-table \
    --table-name "$DDB_TABLE" \
    --profile "$PROFILE" --region "$REGION" \
    --query 'Table.BillingModeSummary.BillingMode' --output text 2>&1) || {
    log_err "describe-table failed: $billing"
    exit 1
}
log_info "Current billing mode: ${billing}"

if [[ "$billing" == "PROVISIONED" ]]; then
    wcu=$(aws dynamodb describe-table \
        --table-name "$DDB_TABLE" \
        --profile "$PROFILE" --region "$REGION" \
        --query 'Table.ProvisionedThroughput.WriteCapacityUnits' --output text)
    if [[ "$wcu" == "5" ]]; then
        log_ok "DDB already PROVISIONED 5/5 - skipping (b)"
    else
        log_action "Updating ${DDB_TABLE} provisioned throughput to 5/5"
        aws dynamodb update-table \
            --table-name "$DDB_TABLE" \
            --provisioned-throughput "ReadCapacityUnits=5,WriteCapacityUnits=5" \
            --profile "$PROFILE" --region "$REGION" \
            --no-cli-pager >/dev/null
    fi
else
    log_action "Switching ${DDB_TABLE} to PROVISIONED 5/5"
    if ! confirm "Switch DDB ${DDB_TABLE} to PROVISIONED 5/5?"; then
        log_warn "User declined L5(b). Skipping."
    else
        aws dynamodb update-table \
            --table-name "$DDB_TABLE" \
            --billing-mode PROVISIONED \
            --provisioned-throughput "ReadCapacityUnits=5,WriteCapacityUnits=5" \
            --profile "$PROFILE" --region "$REGION" \
            --no-cli-pager >/dev/null
        log_ok "DDB switched to PROVISIONED 5/5"
    fi
fi

# (c) Invoke etl-trigger to push 100 items.
log_action "Invoking ${LAMBDA_NAME} with payload {\"count\": 100}"
invoke_out=$(mktemp)
trap 'rm -f "$invoke_out"' EXIT

if ! aws lambda invoke \
        --function-name "$LAMBDA_NAME" \
        --payload "$(printf '{"count":100}' | base64)" \
        --profile "$PROFILE" --region "$REGION" \
        --no-cli-pager \
        "$invoke_out" >/dev/null 2>&1; then
    # Some CLI versions require --cli-binary-format raw-in-base64-out
    log_warn "Default invoke failed; retrying with --cli-binary-format raw-in-base64-out"
    aws lambda invoke \
        --function-name "$LAMBDA_NAME" \
        --cli-binary-format raw-in-base64-out \
        --payload '{"count":100}' \
        --profile "$PROFILE" --region "$REGION" \
        --no-cli-pager \
        "$invoke_out" >/dev/null
fi
log_ok "Lambda invoke complete. Response payload size: $(wc -c <"$invoke_out") bytes"

# (d) Scale ECS to 5.
current_count=$(aws ecs describe-services \
    --cluster "$CLUSTER" --services "$SERVICE" \
    --profile "$PROFILE" --region "$REGION" \
    --query 'services[0].desiredCount' --output text)
if [[ "$current_count" == "$TARGET_COUNT" ]]; then
    log_ok "ECS already at desired-count=${TARGET_COUNT}"
else
    log_action "Scaling ${SERVICE} desired-count: ${current_count} -> ${TARGET_COUNT}"
    aws ecs update-service \
        --cluster "$CLUSTER" --service "$SERVICE" \
        --desired-count "$TARGET_COUNT" \
        --profile "$PROFILE" --region "$REGION" \
        --no-cli-pager >/dev/null
    log_ok "ECS scaled to ${TARGET_COUNT}"
fi

log_ok "L5 inject complete. Watch for OOM exits + DDB throttle in CloudWatch."
