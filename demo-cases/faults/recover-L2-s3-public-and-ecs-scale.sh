#!/usr/bin/env bash
# L2 recover: re-enable public access block on china-data-output bucket
# and scale ECS etl-worker back to 1.
unset AWS_PROFILE AWS_REGION
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

trap 'on_error $LINENO' ERR
parse_debug_flag "$@"

PROFILE="$FAULT_CHINA_PROFILE"
REGION="$FAULT_CHINA_REGION"
PREFIX="$FAULT_CHINA_S3_OUTPUT_PREFIX"
CLUSTER="$FAULT_CHINA_ECS_CLUSTER"
SERVICE="$FAULT_CHINA_ECS_ETL_SERVICE"
TARGET_COUNT=1

log_step "L2 RECOVER - re-secure S3 + scale ECS down"

validate_profile "$PROFILE" "" "$REGION"

# (a) Re-secure bucket
log_info "Searching for bucket starting with '${PREFIX}-'..."
bucket=$(aws s3api list-buckets \
    --profile "$PROFILE" --region "$REGION" \
    --query "Buckets[?starts_with(Name,\`${PREFIX}-\`)].Name | [0]" \
    --output text 2>&1) || {
    log_err "list-buckets failed: $bucket"
    exit 1
}

if [[ -z "$bucket" || "$bucket" == "None" ]]; then
    log_warn "No bucket found - assuming already deleted/never created. Skipping S3 portion."
else
    log_action "Will delete public bucket policy and re-enable PublicAccessBlock on ${bucket}"

    # delete-bucket-policy is idempotent (404 if no policy) - swallow.
    aws s3api delete-bucket-policy \
        --bucket "$bucket" \
        --profile "$PROFILE" --region "$REGION" \
        --no-cli-pager 2>/dev/null || \
        log_info "No bucket policy to delete (or already absent)."

    aws s3api put-public-access-block \
        --bucket "$bucket" \
        --public-access-block-configuration \
            "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" \
        --profile "$PROFILE" --region "$REGION" \
        --no-cli-pager >/dev/null
    log_ok "L2(a) recovered: ${bucket} now private (PAB re-enabled)"
fi

# (b) ECS scale down
current_count=$(aws ecs describe-services \
    --cluster "$CLUSTER" --services "$SERVICE" \
    --profile "$PROFILE" --region "$REGION" \
    --query 'services[0].desiredCount' --output text 2>&1) || {
    log_warn "describe-services failed: $current_count - service may not exist. Skipping ECS portion."
    current_count="MISSING"
}

if [[ "$current_count" == "MISSING" ]]; then
    :
elif [[ "$current_count" == "$TARGET_COUNT" ]]; then
    log_ok "ECS already at desired-count=${TARGET_COUNT} - nothing to recover."
else
    log_action "Scaling ${SERVICE}: ${current_count} -> ${TARGET_COUNT}"
    aws ecs update-service \
        --cluster "$CLUSTER" --service "$SERVICE" \
        --desired-count "$TARGET_COUNT" \
        --profile "$PROFILE" --region "$REGION" \
        --no-cli-pager >/dev/null
    log_ok "L2(b) recovered: ${SERVICE} desired-count=${TARGET_COUNT}"
fi

log_ok "L2 recover complete."
