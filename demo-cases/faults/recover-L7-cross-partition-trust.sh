#!/usr/bin/env bash
# L7 recover: delete the trigger Lambda + its execution role.
# The broken IAM role itself is the demo artifact - it stays.
unset AWS_PROFILE AWS_REGION
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

trap 'on_error $LINENO' ERR
parse_debug_flag "$@"

PROFILE="$FAULT_BJS1_PROFILE"
REGION="$FAULT_BJS1_REGION"
LAMBDA_NAME="bjs-cross-partition-trigger"
LAMBDA_ROLE_NAME="bjs-cross-partition-trigger-role"

log_step "L7 RECOVER - delete probe Lambda + role"

validate_profile "$PROFILE" "" "$REGION"

# Delete Lambda.
if aws lambda get-function \
        --function-name "$LAMBDA_NAME" \
        --profile "$PROFILE" --region "$REGION" \
        --no-cli-pager >/dev/null 2>&1; then
    log_action "Deleting Lambda ${LAMBDA_NAME}"
    aws lambda delete-function \
        --function-name "$LAMBDA_NAME" \
        --profile "$PROFILE" --region "$REGION" \
        --no-cli-pager
    log_ok "Lambda deleted"
else
    log_ok "Lambda ${LAMBDA_NAME} already absent"
fi

# Delete role (detach policies first).
if aws iam get-role \
        --role-name "$LAMBDA_ROLE_NAME" \
        --profile "$PROFILE" --no-cli-pager >/dev/null 2>&1; then
    log_action "Cleaning up role ${LAMBDA_ROLE_NAME}"

    attached=$(aws iam list-attached-role-policies \
        --role-name "$LAMBDA_ROLE_NAME" \
        --profile "$PROFILE" --no-cli-pager \
        --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null || echo "")
    for arn in $attached; do
        [[ -n "$arn" && "$arn" != "None" ]] || continue
        aws iam detach-role-policy \
            --role-name "$LAMBDA_ROLE_NAME" --policy-arn "$arn" \
            --profile "$PROFILE" --no-cli-pager
    done

    inline=$(aws iam list-role-policies \
        --role-name "$LAMBDA_ROLE_NAME" \
        --profile "$PROFILE" --no-cli-pager \
        --query 'PolicyNames[]' --output text 2>/dev/null || echo "")
    for p in $inline; do
        [[ -n "$p" && "$p" != "None" ]] || continue
        aws iam delete-role-policy \
            --role-name "$LAMBDA_ROLE_NAME" --policy-name "$p" \
            --profile "$PROFILE" --no-cli-pager
    done

    aws iam delete-role \
        --role-name "$LAMBDA_ROLE_NAME" \
        --profile "$PROFILE" --no-cli-pager
    log_ok "Role deleted"
else
    log_ok "Role ${LAMBDA_ROLE_NAME} already absent"
fi

log_ok "L7 recover complete. (Broken cross-partition-test-role stays as demo artifact.)"
