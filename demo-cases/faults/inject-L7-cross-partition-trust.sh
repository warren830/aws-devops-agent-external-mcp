#!/usr/bin/env bash
# L7 inject: deploy a tiny Lambda that calls sts:AssumeRole on the broken
# cross-partition role baked into terraform. The call fails (because the
# trust policy uses 'arn:aws:' instead of 'arn:aws-cn:'), CloudTrail records
# the AccessDenied. Drives Case C5 (agent makes wrong dx, custom skill saves).
#
# The IAM role itself is the demo artifact - it stays. We only manage the
# trigger Lambda + a one-off invoke that produces the failed CloudTrail event.
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

log_step "L7 INJECT - deploy + invoke cross-partition AssumeRole probe Lambda"

validate_profile "$PROFILE" "" "$REGION"

ACCOUNT_ID=$(aws sts get-caller-identity --profile "$PROFILE" \
    --query Account --output text)
TARGET_ROLE_ARN="arn:aws-cn:iam::${ACCOUNT_ID}:role/${BROKEN_ROLE}"
log_info "Target broken role ARN: ${TARGET_ROLE_ARN}"

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# 1. Ensure execution role exists for the trigger Lambda.
log_info "Ensuring Lambda execution role ${LAMBDA_ROLE_NAME} exists..."
exec_role_arn=$(aws iam get-role \
    --role-name "$LAMBDA_ROLE_NAME" \
    --profile "$PROFILE" --no-cli-pager \
    --query 'Role.Arn' --output text 2>/dev/null || echo "")

if [[ -z "$exec_role_arn" ]]; then
    log_action "Creating execution role ${LAMBDA_ROLE_NAME}"
    cat >"${WORKDIR}/trust.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "lambda.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}
EOF
    exec_role_arn=$(aws iam create-role \
        --role-name "$LAMBDA_ROLE_NAME" \
        --assume-role-policy-document "file://${WORKDIR}/trust.json" \
        --profile "$PROFILE" --no-cli-pager \
        --query 'Role.Arn' --output text)

    aws iam attach-role-policy \
        --role-name "$LAMBDA_ROLE_NAME" \
        --policy-arn "arn:aws-cn:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole" \
        --profile "$PROFILE" --no-cli-pager

    # Inline policy granting sts:AssumeRole on anything (we expect AccessDenied
    # from the broken trust policy, not from the caller's permissions).
    cat >"${WORKDIR}/sts-policy.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": "sts:AssumeRole",
    "Resource": "*"
  }]
}
EOF
    aws iam put-role-policy \
        --role-name "$LAMBDA_ROLE_NAME" \
        --policy-name "allow-sts-assume" \
        --policy-document "file://${WORKDIR}/sts-policy.json" \
        --profile "$PROFILE" --no-cli-pager

    log_info "Sleeping 10s for IAM eventual consistency..."
    sleep 10
fi
log_ok "Execution role ARN: ${exec_role_arn}"

# 2. Build inline zip.
cat >"${WORKDIR}/lambda_function.py" <<PYEOF
import boto3, os, json
def handler(event, context):
    target = os.environ["TARGET_ROLE_ARN"]
    sts = boto3.client("sts")
    try:
        resp = sts.assume_role(RoleArn=target, RoleSessionName="cross-partition-probe")
        return {"status": "unexpected_success", "arn": resp["AssumedRoleUser"]["Arn"]}
    except Exception as e:
        return {"status": "expected_failure", "error": str(e)}
PYEOF
( cd "$WORKDIR" && zip -q lambda.zip lambda_function.py )

# 3. Create or update Lambda.
if aws lambda get-function \
        --function-name "$LAMBDA_NAME" \
        --profile "$PROFILE" --region "$REGION" \
        --no-cli-pager >/dev/null 2>&1; then
    log_action "Lambda ${LAMBDA_NAME} exists - updating code + env"
    aws lambda update-function-code \
        --function-name "$LAMBDA_NAME" \
        --zip-file "fileb://${WORKDIR}/lambda.zip" \
        --profile "$PROFILE" --region "$REGION" \
        --no-cli-pager >/dev/null
    # Wait for code update to settle before update-configuration
    aws lambda wait function-updated \
        --function-name "$LAMBDA_NAME" \
        --profile "$PROFILE" --region "$REGION" 2>/dev/null || true
    aws lambda update-function-configuration \
        --function-name "$LAMBDA_NAME" \
        --environment "Variables={TARGET_ROLE_ARN=${TARGET_ROLE_ARN}}" \
        --profile "$PROFILE" --region "$REGION" \
        --no-cli-pager >/dev/null
else
    log_action "Creating Lambda ${LAMBDA_NAME}"
    aws lambda create-function \
        --function-name "$LAMBDA_NAME" \
        --runtime python3.11 \
        --role "$exec_role_arn" \
        --handler lambda_function.handler \
        --zip-file "fileb://${WORKDIR}/lambda.zip" \
        --environment "Variables={TARGET_ROLE_ARN=${TARGET_ROLE_ARN}}" \
        --timeout 10 \
        --profile "$PROFILE" --region "$REGION" \
        --no-cli-pager >/dev/null
fi

# 4. Wait active then invoke.
log_info "Waiting for Lambda to be active..."
aws lambda wait function-active \
    --function-name "$LAMBDA_NAME" \
    --profile "$PROFILE" --region "$REGION" 2>/dev/null || true

invoke_out=$(mktemp)
log_action "Invoking ${LAMBDA_NAME} (expect AccessDenied)"
aws lambda invoke \
    --function-name "$LAMBDA_NAME" \
    --profile "$PROFILE" --region "$REGION" \
    --no-cli-pager \
    "$invoke_out" >/dev/null

log_info "Invoke response payload:"
cat "$invoke_out"
echo
rm -f "$invoke_out"

log_ok "L7 inject complete. CloudTrail will record the failed AssumeRole."
log_info "Search CloudTrail with eventName=AssumeRole, errorCode=AccessDenied, resource=${BROKEN_ROLE}"
