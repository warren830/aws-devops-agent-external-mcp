#!/usr/bin/env bash
# inject-all: chain every L1-L9 inject script.
#
# Defaults to interactive (one prompt per fault). Pass --yes to auto-confirm
# each individual script. Pass --skip Lx,Ly to skip specific faults.
#
# Example:
#   ./inject-all.sh                 # interactive
#   FAULT_AUTO_YES=1 ./inject-all.sh --yes
#   ./inject-all.sh --skip L4,L7    # everything except L4 and L7
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
        --skip)     ;; # consumed by next arg
        --skip=*)   SKIP_LIST="${arg#--skip=}" ;;
        --debug)    ;; # already handled by parse_debug_flag
        L*,*|L*)
            # If preceded by --skip arg, treat as skip list.
            if [[ "$prev_arg" == "--skip" ]]; then SKIP_LIST="$arg"; fi
            ;;
    esac
    prev_arg="$arg"
done

# Re-parse for `--skip Lx,Ly` form
prev=""
for arg in "$@"; do
    if [[ "$prev" == "--skip" ]]; then SKIP_LIST="$arg"; fi
    prev="$arg"
done

is_skipped() {
    local id="$1"
    [[ ",${SKIP_LIST}," == *",${id},"* ]]
}

FAULTS=(L1 L2 L3 L4 L5 L6 L7 L8 L9)

declare -A SCRIPTS=(
    [L1]="inject-L1-rds-no-multi-az.sh"
    [L2]="inject-L2-s3-public-and-ecs-scale.sh"
    [L3]="inject-L3-iam-key-old.sh"
    [L4]="inject-L4-unindexed-query-load.sh"
    [L5]="inject-L5-etl-oom-ddb-throttle.sh"
    [L6]="inject-L6-pod-imagepullbackoff.sh"
    [L7]="inject-L7-cross-partition-trust.sh"
    [L8]="inject-L8-alb-healthcheck-240s.sh"
    [L9]="inject-L9-pod-cpu-limit.sh"
)

log_step "INJECT ALL FAULTS (L1-L9)"
[[ -n "$SKIP_LIST" ]] && log_warn "Skipping: ${SKIP_LIST}"
log_info "FAULT_AUTO_YES=${FAULT_AUTO_YES:-0}"

failed=()
skipped=()
ran=()

for f in "${FAULTS[@]}"; do
    if is_skipped "$f"; then
        log_warn "Skipping ${f} (per --skip)"
        skipped+=("$f")
        continue
    fi
    script="${SCRIPT_DIR}/${SCRIPTS[$f]}"
    if [[ ! -x "$script" ]]; then
        # Allow non-executable but readable scripts (run via bash explicitly).
        if [[ ! -f "$script" ]]; then
            log_err "Missing script: $script"
            failed+=("$f")
            continue
        fi
    fi
    log_step "Running ${f}: $(basename "$script")"
    if bash "$script"; then
        ran+=("$f")
    else
        log_err "${f} failed."
        failed+=("$f")
    fi
done

echo
log_step "INJECT-ALL SUMMARY"
log_info "Ran    : ${ran[*]:-<none>}"
log_info "Skipped: ${skipped[*]:-<none>}"
if [[ ${#failed[@]} -gt 0 ]]; then
    log_err "Failed : ${failed[*]}"
    exit 1
fi
log_ok "All requested faults injected."
