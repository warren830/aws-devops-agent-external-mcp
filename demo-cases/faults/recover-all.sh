#!/usr/bin/env bash
# recover-all: chain every L1-L9 recover script in REVERSE order
# (so traffic / load gen stops first, then service-level recoveries).
#
# Recovery scripts are idempotent so this is always safe to run.
unset AWS_PROFILE AWS_REGION
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

trap 'on_error $LINENO' ERR
parse_debug_flag "$@"

SKIP_LIST=""
for arg in "$@"; do
    case "$arg" in
        --yes|-y)   export FAULT_AUTO_YES=1 ;;
        --skip=*)   SKIP_LIST="${arg#--skip=}" ;;
    esac
done
prev=""
for arg in "$@"; do
    if [[ "$prev" == "--skip" ]]; then SKIP_LIST="$arg"; fi
    prev="$arg"
done

is_skipped() {
    local id="$1"
    [[ ",${SKIP_LIST}," == *",${id},"* ]]
}

# Reverse order so loadgen + ECS scale stop before service-level reverts.
FAULTS=(L9 L8 L7 L6 L5 L4 L3 L2 L1)

declare -A SCRIPTS=(
    [L1]="recover-L1-rds-no-multi-az.sh"
    [L2]="recover-L2-s3-public-and-ecs-scale.sh"
    [L3]="recover-L3-iam-key-old.sh"
    [L4]="recover-L4-unindexed-query-load.sh"
    [L5]="recover-L5-etl-oom-ddb-throttle.sh"
    [L6]="recover-L6-pod-imagepullbackoff.sh"
    [L7]="recover-L7-cross-partition-trust.sh"
    [L8]="recover-L8-alb-healthcheck-240s.sh"
    [L9]="recover-L9-pod-cpu-limit.sh"
)

log_step "RECOVER ALL FAULTS (L9 -> L1)"
[[ -n "$SKIP_LIST" ]] && log_warn "Skipping: ${SKIP_LIST}"

failed=()
ran=()
skipped=()

for f in "${FAULTS[@]}"; do
    if is_skipped "$f"; then
        log_warn "Skipping ${f}"
        skipped+=("$f")
        continue
    fi
    script="${SCRIPT_DIR}/${SCRIPTS[$f]}"
    if [[ ! -f "$script" ]]; then
        log_err "Missing script: $script"
        failed+=("$f")
        continue
    fi
    log_step "Running ${f}: $(basename "$script")"
    # Run in subshell with || to avoid set -e from killing the whole loop.
    if bash "$script"; then
        ran+=("$f")
    else
        log_err "${f} recover failed - continuing with rest."
        failed+=("$f")
    fi
done

echo
log_step "RECOVER-ALL SUMMARY"
log_info "Ran    : ${ran[*]:-<none>}"
log_info "Skipped: ${skipped[*]:-<none>}"
if [[ ${#failed[@]} -gt 0 ]]; then
    log_err "Failed : ${failed[*]}"
    log_warn "Re-run individual scripts to investigate."
    exit 1
fi
log_ok "All requested faults recovered."
