#!/usr/bin/env bash
# L4 recover: stop the background load generator started by inject-L4.
# Idempotent.
#
# Note: the underlying unindexed-query bug is in app code; the real fix is
# to land migration 0002_add_users_email_index.sql via C7's PR. This script
# only stops the traffic.
unset AWS_PROFILE AWS_REGION
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

trap 'on_error $LINENO' ERR
parse_debug_flag "$@"

PIDFILE="${FAULT_METADATA_DIR}/L4-load.pid"
LOADGEN_PY="${FAULT_METADATA_DIR}/.L4-load.py"

log_step "L4 RECOVER - stop load generator"

if [[ ! -f "$PIDFILE" ]]; then
    log_ok "No L4 load pidfile - nothing to stop."
    exit 0
fi

pid=$(cat "$PIDFILE" 2>/dev/null || echo "")

if [[ -z "$pid" ]]; then
    log_warn "Empty pidfile - removing."
    rm -f "$PIDFILE"
    exit 0
fi

if kill -0 "$pid" 2>/dev/null; then
    log_action "Killing load generator pid ${pid}"
    kill "$pid" 2>/dev/null || true
    sleep 1
    if kill -0 "$pid" 2>/dev/null; then
        log_warn "Process still alive - sending SIGKILL"
        kill -9 "$pid" 2>/dev/null || true
    fi
    log_ok "Load generator stopped."
else
    log_info "Process ${pid} already exited."
fi

rm -f "$PIDFILE"
[[ -f "$LOADGEN_PY" ]] && rm -f "$LOADGEN_PY"
log_ok "L4 recover complete. (App-level bug fix is C7's PR; this script only stops traffic.)"
