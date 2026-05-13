#!/usr/bin/env bash
# L2 inject: china-data-output bucket public + ECS etl-worker scale anomaly.
# Drives Case C10 (cost anomaly + ops backlog).
#
# Steps:
#   (a) Find bucket matching china-data-output-* and disable Public Access Block
#   (b) Bump ECS service etl-worker desired-count to 20 (simulate runaway)
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
TARGET_COUNT=20

log_step "L2 INJECT - china S3 public + ECS scale anomaly"

validate_profile "$PROFILE" "" "$REGION"

# (a) Find bucket
log_info "Searching for bucket starting with '${PREFIX}-'..."
bucket=$(aws s3api list-buckets \
    --profile "$PROFILE" --region "$REGION" \
    --query "Buckets[?starts_with(Name,\`${PREFIX}-\`)].Name | [0]" \
    --output text 2>&1) || {
    log_err "list-buckets failed: $bucket"
    exit 1
}

if [[ -z "$bucket" || "$bucket" == "None" ]]; then
    log_err "No bucket found starting with '${PREFIX}-'. Did infra deploy?"
    exit 1
fi
log_info "Target bucket: ${bucket}"

log_action "Will DELETE PublicAccessBlock on s3://${bucket} (data-leak demo)"
if ! confirm "Proceed with disabling public-access-block on ${bucket}?"; then
    log_warn "User declined L2(a). Skipping S3 portion."
else
    aws s3api delete-public-access-block \
        --bucket "$bucket" \
        --profile "$PROFILE" --region "$REGION" \
        --no-cli-pager 2>/dev/null || \
        log_warn "delete-public-access-block returned non-zero (already absent?). Continuing."

    # Also set a permissive bucket policy so the bucket is *actually* public
    # (PublicAccessBlock alone only removes the safety net; without a policy
    # it would still be private). For the demo we add a public-read policy.
    log_action "Applying public-read bucket policy to ${bucket}"
    policy_json=$(cat <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "DemoPublicReadL2",
            "Effect": "Allow",
            "Principal": "*",
            "Action": ["s3:GetObject"],
            "Resource": "arn:aws-cn:s3:::${bucket}/*"
        }
    ]
}
EOF
)
    if ! aws s3api put-bucket-policy \
        --bucket "$bucket" \
        --policy "$policy_json" \
        --profile "$PROFILE" --region "$REGION" \
        --no-cli-pager 2>/dev/null; then
        log_warn "put-bucket-policy failed (PublicAccessBlock may still be enforcing). Re-run after delete-public-access-block propagates."
    fi
    log_ok "L2(a) S3 public injected on ${bucket}"
fi

# (b) ECS scale anomaly
log_info "Reading current desired-count for ${CLUSTER}/${SERVICE}..."
current_count=$(aws ecs describe-services \
    --cluster "$CLUSTER" --services "$SERVICE" \
    --profile "$PROFILE" --region "$REGION" \
    --query 'services[0].desiredCount' --output text 2>&1) || {
    log_err "describe-services failed: $current_count"
    exit 1
}
log_info "Current desired-count = ${current_count}"

if [[ "$current_count" == "$TARGET_COUNT" ]]; then
    log_ok "Already at desired-count=${TARGET_COUNT} - L2(b) idempotent skip."
else
    log_action "Will scale ECS service ${SERVICE} desired-count: ${current_count} -> ${TARGET_COUNT}"
    if confirm "Proceed with scaling ${SERVICE} to ${TARGET_COUNT} tasks?"; then
        aws ecs update-service \
            --cluster "$CLUSTER" --service "$SERVICE" \
            --desired-count "$TARGET_COUNT" \
            --profile "$PROFILE" --region "$REGION" \
            --no-cli-pager >/dev/null
        log_ok "L2(b) ECS scaled to ${TARGET_COUNT}"
    else
        log_warn "User declined L2(b)."
    fi
fi

log_ok "L2 inject finished. Public bucket + runaway ECS in place for C10."
