#!/usr/bin/env bash
# L4 inject: drive load against bjs-todo-api /api/users/search to surface
# the unindexed-query latency that's already baked into the application code.
# Drives Cases C2 / C7 / C9.
#
# Tries `hey` first, then `ab`, then a python aiohttp fallback.
# Runs for 5 minutes at ~50 RPS by default.
unset AWS_PROFILE AWS_REGION
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

trap 'on_error $LINENO' ERR
parse_debug_flag "$@"

URL="${BJS_WEB_URL%/}/api/users/search?email=test@example.com"
DURATION="${L4_DURATION:-5m}"
RPS="${L4_RPS:-50}"
PIDFILE="${FAULT_METADATA_DIR}/L4-load.pid"

log_step "L4 INJECT - drive search-endpoint load to surface unindexed query"

log_info "Target URL: ${URL}"
log_info "Duration  : ${DURATION}"
log_info "Target RPS: ${RPS}"

if [[ -f "$PIDFILE" ]]; then
    existing=$(cat "$PIDFILE" 2>/dev/null || echo "")
    if [[ -n "$existing" ]] && kill -0 "$existing" 2>/dev/null; then
        log_warn "Load generator already running (pid ${existing}). Stop with recover-L4 first."
        exit 0
    else
        log_info "Stale pidfile - removing."
        rm -f "$PIDFILE"
    fi
fi

log_action "About to start background load generator against ${URL}"
if ! confirm "Start load against ${URL} for ${DURATION}?"; then
    log_warn "User declined - aborting."
    exit 1
fi

# Convert duration like "5m" / "300s" into seconds for the python fallback.
duration_to_seconds() {
    local d="$1"
    case "$d" in
        *s) echo "${d%s}" ;;
        *m) echo "$(( ${d%m} * 60 ))" ;;
        *h) echo "$(( ${d%h} * 3600 ))" ;;
        *)  echo "$d" ;;
    esac
}
DURATION_SEC=$(duration_to_seconds "$DURATION")

if command -v hey >/dev/null 2>&1; then
    log_info "Using 'hey' load generator."
    nohup hey -z "$DURATION" -q "$RPS" -c 10 "$URL" \
        >"${FAULT_METADATA_DIR}/L4-load.out" 2>&1 &
    echo $! >"$PIDFILE"
elif command -v ab >/dev/null 2>&1; then
    log_info "Using 'ab' load generator."
    # ab can't do duration directly; approximate total requests = RPS * sec.
    total=$(( RPS * DURATION_SEC ))
    nohup ab -n "$total" -c 10 "$URL" \
        >"${FAULT_METADATA_DIR}/L4-load.out" 2>&1 &
    echo $! >"$PIDFILE"
else
    log_info "Falling back to python aiohttp loadgen (5 concurrent workers)."
    if ! python3 -c 'import aiohttp' 2>/dev/null; then
        log_err "Neither hey/ab installed and python3 aiohttp unavailable."
        log_err "Install with: brew install hey  OR  pip3 install aiohttp"
        exit 1
    fi
    cat >"${FAULT_METADATA_DIR}/.L4-load.py" <<'PYEOF'
import asyncio, aiohttp, sys, time

URL = sys.argv[1]
DURATION = float(sys.argv[2])
RPS = int(sys.argv[3])
CONCURRENCY = 10

async def worker(session, deadline, interval):
    while time.time() < deadline:
        start = time.time()
        try:
            async with session.get(URL, timeout=aiohttp.ClientTimeout(total=10)) as r:
                await r.read()
        except Exception:
            pass
        elapsed = time.time() - start
        if elapsed < interval:
            await asyncio.sleep(interval - elapsed)

async def main():
    deadline = time.time() + DURATION
    interval = CONCURRENCY / RPS  # per-worker interval to hit aggregate RPS
    connector = aiohttp.TCPConnector(limit=0, ssl=False)
    async with aiohttp.ClientSession(connector=connector) as session:
        await asyncio.gather(*[worker(session, deadline, interval) for _ in range(CONCURRENCY)])

asyncio.run(main())
PYEOF
    nohup python3 "${FAULT_METADATA_DIR}/.L4-load.py" "$URL" "$DURATION_SEC" "$RPS" \
        >"${FAULT_METADATA_DIR}/L4-load.out" 2>&1 &
    echo $! >"$PIDFILE"
fi

LOAD_PID=$(cat "$PIDFILE")
log_ok "Load generator started (pid ${LOAD_PID}). Output: ${FAULT_METADATA_DIR}/L4-load.out"
log_info "Use recover-L4 to stop early, or wait for natural completion."
