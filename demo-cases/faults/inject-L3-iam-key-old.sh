#!/usr/bin/env bash
# L3 inject: create demo IAM user + access key for the "65-day-old key"
# rotation demo (drives Case C6 prevention).
#
# AWS LIMITATION: there is no API to backdate access-key CreateDate. Two
# options for the demo:
#   1. Create the user 65+ days BEFORE the demo and let the key age naturally.
#   2. Create the key now and tell the prevention skill the simulated
#      "current date" is 65 days after creation. We pick option 2 for
#      reproducibility - the metadata file written here records the simulated
#      age that other scripts/skills can pick up.
#
# Inject is idempotent: if the user/key already exist, we reuse them.
unset AWS_PROFILE AWS_REGION
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

trap 'on_error $LINENO' ERR
parse_debug_flag "$@"

PROFILE="$FAULT_BJS1_PROFILE"
REGION="$FAULT_BJS1_REGION"
USER_NAME="$FAULT_BJS1_DEMO_USER"
SIMULATED_AGE_DAYS=65

METADATA_FILE="${FAULT_METADATA_DIR}/L3-simulated-metadata.json"

log_step "L3 INJECT - create demo IAM user '${USER_NAME}' + access key (simulated 65-day age)"

validate_profile "$PROFILE" "" "$REGION"

# Step 1: ensure IAM user exists.
if aws iam get-user --user-name "$USER_NAME" --profile "$PROFILE" \
        --no-cli-pager >/dev/null 2>&1; then
    log_info "IAM user '${USER_NAME}' already exists - reusing."
else
    log_action "Creating IAM user ${USER_NAME} (no policies attached)"
    if ! confirm "Create IAM user ${USER_NAME}?"; then
        log_warn "User declined - aborting."
        exit 1
    fi
    aws iam create-user \
        --user-name "$USER_NAME" \
        --tags Key=Purpose,Value=demo-l3-rotation Key=ManagedBy,Value=fault-inject-script \
        --profile "$PROFILE" --no-cli-pager >/dev/null
    log_ok "Created IAM user ${USER_NAME}"
fi

# Step 2: ensure at least one access key exists for this user.
existing_keys=$(aws iam list-access-keys \
    --user-name "$USER_NAME" \
    --profile "$PROFILE" --no-cli-pager \
    --query 'AccessKeyMetadata[].AccessKeyId' --output text 2>&1) || {
    log_err "list-access-keys failed: $existing_keys"
    exit 1
}

access_key_id=""
real_create_date=""
if [[ -n "$existing_keys" && "$existing_keys" != "None" ]]; then
    # Pick first existing.
    access_key_id=$(printf '%s\n' "$existing_keys" | awk '{print $1}')
    log_info "Reusing existing access key ${access_key_id}"
    real_create_date=$(aws iam list-access-keys \
        --user-name "$USER_NAME" \
        --profile "$PROFILE" --no-cli-pager \
        --query "AccessKeyMetadata[?AccessKeyId=='${access_key_id}'].CreateDate" \
        --output text)
else
    log_action "Creating new access key for ${USER_NAME}"
    create_json=$(aws iam create-access-key \
        --user-name "$USER_NAME" \
        --profile "$PROFILE" --no-cli-pager \
        --output json)
    access_key_id=$(printf '%s' "$create_json" | python3 -c \
        'import json,sys; print(json.load(sys.stdin)["AccessKey"]["AccessKeyId"])')
    real_create_date=$(printf '%s' "$create_json" | python3 -c \
        'import json,sys; print(json.load(sys.stdin)["AccessKey"]["CreateDate"])')
    log_ok "Created access key ${access_key_id}"
    log_warn "Secret access key is NOT logged. Retrieve from AWS console if needed."
fi

# Step 3: write simulated metadata file.
# We deliberately compute "simulated_create_date = now - 65d" so that any
# downstream skill that reads this file sees a 65-day-old key without us
# touching IAM's actual CreateDate (which we can't).
simulated_create_date=$(python3 -c "
from datetime import datetime, timedelta, timezone
print((datetime.now(timezone.utc) - timedelta(days=${SIMULATED_AGE_DAYS})).isoformat())
")

python3 - <<PYEOF >"$METADATA_FILE"
import json, os
data = {
    "fault": "L3",
    "user_name": "${USER_NAME}",
    "access_key_id": "${access_key_id}",
    "real_create_date": "${real_create_date}",
    "simulated_create_date": "${simulated_create_date}",
    "simulated_age_days": ${SIMULATED_AGE_DAYS},
    "note": "AWS API does not allow backdating access-key CreateDate. The prevention skill should treat 'simulated_create_date' as the canonical timestamp for this demo.",
}
print(json.dumps(data, indent=2))
PYEOF

log_ok "Wrote simulated metadata: ${METADATA_FILE}"
log_info "  user           : ${USER_NAME}"
log_info "  access_key_id  : ${access_key_id}"
log_info "  real_create    : ${real_create_date}"
log_info "  simulated_create: ${simulated_create_date}"
log_warn "Tell the C6 prevention skill: simulated key age = ${SIMULATED_AGE_DAYS} days (>60 = rotation due)"
