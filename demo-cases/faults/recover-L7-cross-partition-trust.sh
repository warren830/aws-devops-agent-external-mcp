#!/usr/bin/env bash
# L7 recover: reset the cross-partition-test-role trust policy back to a
# valid baseline (cn-partition self-account principal), AND delete the
# trigger Lambda + its execution role.
unset AWS_PROFILE AWS_REGION
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

trap 'on_error $LINENO' ERR
parse_debug_flag "$@"

PROFILE="$FAULT_BJS1_PROFILE"
REGION="$FAULT_BJS1_REGION"
BROKEN_ROLE="$FAULT_BJS1_BROKEN_ROLE"
LAMBDA_NAME="bjs-cross-partition-trigger"
LAMBDA_ROLE_NAME="bjs-cross-partition-trigger-role"

log_step "L7 RECOVER - reset trust policy + delete probe Lambda + role"

validate_profile "$PROFILE" "" "$REGION"

ACCOUNT_ID=$(aws sts get-caller-identity --profile "$PROFILE" \
    --query Account --output text)

# Reset the broken role's trust policy to the valid cn-partition baseline.
if aws iam get-role --role-name "$BROKEN_ROLE" \
        --profile "$PROFILE" --no-cli-pager >/dev/null 2>&1; then
    WORKDIR=$(mktemp -d)
    trap 'rm -rf "$WORKDIR"' EXIT
    log_action "Resetting ${BROKEN_ROLE} trust policy to valid cn-partition baseline"
    cat >"${WORKDIR}/valid-trust.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "BaselineValidTrust",
    "Effect": "Allow",
    "Principal": {
      "AWS": "arn:aws-cn:iam::${ACCOUNT_ID}:root"
    },
    "Action": "sts:AssumeRole"
  }]
}
EOF
    aws iam update-assume-role-policy \
        --role-name "$BROKEN_ROLE" \
        --policy-document "file://${WORKDIR}/valid-trust.json" \
        --profile "$PROFILE" --no-cli-pager
    log_ok "Trust policy reset to valid"
else
    log_ok "Role ${BROKEN_ROLE} not present (terraform destroy may have run)"
fi

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

log_ok "L7 recover complete."
