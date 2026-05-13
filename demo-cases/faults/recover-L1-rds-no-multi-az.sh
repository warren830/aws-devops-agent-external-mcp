#!/usr/bin/env bash
# L1 recover: enable Multi-AZ on bjs-todo-db.
# Idempotent - safe to re-run.
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

log_step "L1 RECOVER - bjs1 RDS '${RDS_ID}' enable Multi-AZ"

validate_profile "$PROFILE" "" "$REGION"

current=$(aws rds describe-db-instances \
    --db-instance-identifier "$RDS_ID" \
    --profile "$PROFILE" --region "$REGION" \
    --query 'DBInstances[0].MultiAZ' --output text 2>&1) || {
    log_err "describe-db-instances failed: $current"
    exit 1
}
log_info "Current MultiAZ = ${current}"

if [[ "$current" == "True" ]]; then
    log_ok "Already Multi-AZ - nothing to recover."
    exit 0
fi

log_action "Will set MultiAZ=True on ${RDS_ID} (apply-immediately)"
log_warn "Multi-AZ enable triggers ~5-10 min of standby provisioning. Costs increase."

aws rds modify-db-instance \
    --db-instance-identifier "$RDS_ID" \
    --multi-az \
    --apply-immediately \
    --profile "$PROFILE" --region "$REGION" \
    --no-cli-pager >/dev/null

log_ok "L1 recovered: ${RDS_ID} MultiAZ=True"
