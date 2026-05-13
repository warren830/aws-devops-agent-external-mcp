#!/usr/bin/env bash
# L1 inject: ensure bjs-todo-db RDS is single-AZ.
# Drives Case C6 (predictive evaluation - prevention).
#
# Note: design baseline already has bjs-todo-db single-AZ. Running this script
# at "inject" time merely *re-asserts* single-AZ, so the demo is idempotent
# even after a recover.
unset AWS_PROFILE AWS_REGION
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

trap 'on_error $LINENO' ERR
parse_debug_flag "$@"

PROFILE="$FAULT_BJS1_PROFILE"
REGION="$FAULT_BJS1_REGION"
RDS_ID="$FAULT_BJS1_RDS_ID"

log_step "L1 INJECT - bjs1 RDS '${RDS_ID}' single-AZ"

validate_profile "$PROFILE" "" "$REGION"

# Read current state.
log_info "Reading current MultiAZ state for ${RDS_ID}..."
current=$(aws rds describe-db-instances \
    --db-instance-identifier "$RDS_ID" \
    --profile "$PROFILE" --region "$REGION" \
    --query 'DBInstances[0].MultiAZ' --output text 2>&1) || {
    log_err "describe-db-instances failed: $current"
    exit 1
}
log_info "Current MultiAZ = ${current}"

if [[ "$current" == "False" ]]; then
    log_ok "Already single-AZ - L1 fault state confirmed. Nothing to change."
    exit 0
fi

log_action "Will set MultiAZ=False on ${RDS_ID} (apply-immediately)"
if ! confirm "Proceed with disabling Multi-AZ on ${RDS_ID}?"; then
    log_warn "User declined - aborting."
    exit 1
fi

aws rds modify-db-instance \
    --db-instance-identifier "$RDS_ID" \
    --no-multi-az \
    --apply-immediately \
    --profile "$PROFILE" --region "$REGION" \
    --no-cli-pager >/dev/null

log_ok "L1 fault injected: ${RDS_ID} MultiAZ=False (apply-immediately)"
log_info "RDS will spend a few minutes in 'modifying' state."
