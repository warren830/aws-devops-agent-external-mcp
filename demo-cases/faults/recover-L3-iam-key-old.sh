#!/usr/bin/env bash
# L3 recover: delete the demo IAM user + access key created by inject-L3.
# Idempotent.
unset AWS_PROFILE AWS_REGION
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

trap 'on_error $LINENO' ERR
parse_debug_flag "$@"

PROFILE="$FAULT_BJS1_PROFILE"
USER_NAME="$FAULT_BJS1_DEMO_USER"
METADATA_FILE="${FAULT_METADATA_DIR}/L3-simulated-metadata.json"

log_step "L3 RECOVER - delete demo IAM user '${USER_NAME}' (and all access keys)"

validate_profile "$PROFILE" "" ""

if ! aws iam get-user --user-name "$USER_NAME" --profile "$PROFILE" \
        --no-cli-pager >/dev/null 2>&1; then
    log_ok "IAM user '${USER_NAME}' does not exist - nothing to recover."
    [[ -f "$METADATA_FILE" ]] && rm -f "$METADATA_FILE" && log_info "Removed stale metadata file."
    exit 0
fi

log_action "Will delete all access keys + the user ${USER_NAME}"
if ! confirm "Proceed with deleting IAM user ${USER_NAME}?"; then
    log_warn "User declined - aborting."
    exit 1
fi

# Delete all access keys first (IAM will not delete user with active keys).
keys=$(aws iam list-access-keys \
    --user-name "$USER_NAME" \
    --profile "$PROFILE" --no-cli-pager \
    --query 'AccessKeyMetadata[].AccessKeyId' --output text 2>/dev/null || echo "")

if [[ -n "$keys" && "$keys" != "None" ]]; then
    for k in $keys; do
        log_action "Deleting access key ${k}"
        aws iam delete-access-key \
            --user-name "$USER_NAME" --access-key-id "$k" \
            --profile "$PROFILE" --no-cli-pager
    done
fi

# Detach any policies (defensive - inject didn't attach any, but be safe).
attached=$(aws iam list-attached-user-policies \
    --user-name "$USER_NAME" --profile "$PROFILE" --no-cli-pager \
    --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null || echo "")
if [[ -n "$attached" && "$attached" != "None" ]]; then
    for arn in $attached; do
        log_action "Detaching policy ${arn}"
        aws iam detach-user-policy --user-name "$USER_NAME" --policy-arn "$arn" \
            --profile "$PROFILE" --no-cli-pager
    done
fi

inline=$(aws iam list-user-policies \
    --user-name "$USER_NAME" --profile "$PROFILE" --no-cli-pager \
    --query 'PolicyNames[]' --output text 2>/dev/null || echo "")
if [[ -n "$inline" && "$inline" != "None" ]]; then
    for p in $inline; do
        log_action "Deleting inline policy ${p}"
        aws iam delete-user-policy --user-name "$USER_NAME" --policy-name "$p" \
            --profile "$PROFILE" --no-cli-pager
    done
fi

aws iam delete-user --user-name "$USER_NAME" \
    --profile "$PROFILE" --no-cli-pager

[[ -f "$METADATA_FILE" ]] && rm -f "$METADATA_FILE" && log_info "Removed metadata file."
log_ok "L3 recovered: IAM user ${USER_NAME} deleted."
