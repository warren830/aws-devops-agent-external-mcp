# shellcheck shell=bash
# demo-cases/faults/lib/common.sh
#
# Shared helpers for all fault inject/recover scripts.
#
# Usage:
#   source "$(dirname "$0")/lib/common.sh"
#
# This file is intentionally NOT executable. It is meant to be sourced.
# It does NOT call `set -e` etc. - the caller script is responsible for that
# (so the caller can choose its own strictness, but every script in this dir
# uses `set -euo pipefail`).

# --------------------------------------------------------------------------
# Environment hygiene
# --------------------------------------------------------------------------
# Hard-unset any AWS_PROFILE / AWS_REGION the user might have exported - all
# scripts must pass --profile / --region explicitly. This avoids the classic
# "I thought I was on bjs1 but I was on default" footgun.
unset AWS_PROFILE AWS_REGION AWS_DEFAULT_REGION AWS_DEFAULT_PROFILE 2>/dev/null || true

# --------------------------------------------------------------------------
# Color logging
# --------------------------------------------------------------------------
if [[ -t 1 ]]; then
    _C_RED=$'\033[0;31m'
    _C_GREEN=$'\033[0;32m'
    _C_YELLOW=$'\033[0;33m'
    _C_BLUE=$'\033[0;34m'
    _C_BOLD=$'\033[1m'
    _C_RESET=$'\033[0m'
else
    _C_RED=""
    _C_GREEN=""
    _C_YELLOW=""
    _C_BLUE=""
    _C_BOLD=""
    _C_RESET=""
fi

log_info()  { printf "%s[INFO]%s  %s\n" "$_C_BLUE"   "$_C_RESET" "$*"; }
log_ok()    { printf "%s[ OK ]%s  %s\n" "$_C_GREEN"  "$_C_RESET" "$*"; }
log_warn()  { printf "%s[WARN]%s  %s\n" "$_C_YELLOW" "$_C_RESET" "$*" >&2; }
log_err()   { printf "%s[ERR ]%s  %s\n" "$_C_RED"    "$_C_RESET" "$*" >&2; }
log_step()  { printf "\n%s>>>%s %s%s%s\n" "$_C_BLUE" "$_C_RESET" "$_C_BOLD" "$*" "$_C_RESET"; }

# Echo *what we are about to do* before doing it.
log_action() {
    printf "%s[ACT ]%s %s\n" "$_C_YELLOW" "$_C_RESET" "$*"
}

# --------------------------------------------------------------------------
# Error trap
# --------------------------------------------------------------------------
# Each script that sources this file should register the trap itself
# (we cannot register from a sourced file because $0 / line number context
# differs). Instead we provide a function the script can call:
#
#   trap 'on_error $LINENO' ERR
#
on_error() {
    local lineno="${1:-?}"
    log_err "Script failed at line ${lineno}. Last command exit status: $?"
    log_err "Re-run with --debug to see executed commands."
}

# --------------------------------------------------------------------------
# Profile / region validation
# --------------------------------------------------------------------------
# Verifies that the named profile resolves to a working session and (optionally)
# that sts:GetCallerIdentity returns the expected account. Also checks the
# given region matches what we expect for that account.
#
# Usage:
#   validate_profile <profile> <expected_account_id> <expected_region>
#
# Exits non-zero on mismatch.
validate_profile() {
    local profile="$1"
    local expected_account="${2:-}"
    local expected_region="${3:-}"

    if ! command -v aws >/dev/null 2>&1; then
        log_err "aws CLI not found in PATH"
        return 1
    fi

    log_info "Validating AWS profile: ${profile}"

    local caller_json
    if ! caller_json=$(aws sts get-caller-identity --profile "$profile" --output json 2>&1); then
        log_err "Profile '${profile}' cannot authenticate. Run: aws sso login --profile ${profile}"
        log_err "aws sts get-caller-identity error:"
        printf '%s\n' "$caller_json" >&2
        return 1
    fi

    local actual_account
    actual_account=$(printf '%s' "$caller_json" | python3 -c \
        'import json,sys; print(json.load(sys.stdin)["Account"])' 2>/dev/null) || {
        log_err "Could not parse caller identity JSON"
        return 1
    }

    if [[ -n "$expected_account" && "$actual_account" != "$expected_account" ]]; then
        log_err "Profile '${profile}' resolved to account ${actual_account}, expected ${expected_account}"
        return 1
    fi

    log_ok "Profile '${profile}' authenticated as account ${actual_account}"

    if [[ -n "$expected_region" ]]; then
        # We do not auto-set the region (caller passes --region), but we surface it.
        log_info "Operations will target region: ${expected_region}"
    fi

    return 0
}

# --------------------------------------------------------------------------
# Y/N prompt
# --------------------------------------------------------------------------
# Usage:
#   if confirm "Really inject fault L1?"; then ... fi
#
# Returns 0 (yes) or 1 (no). Default is "no" unless FAULT_AUTO_YES=1 is set
# (used by inject-all.sh / recover-all.sh to chain all faults non-interactively).
confirm() {
    local prompt="$1"
    if [[ "${FAULT_AUTO_YES:-0}" == "1" ]]; then
        log_info "FAULT_AUTO_YES=1 - auto-confirming: ${prompt}"
        return 0
    fi
    local reply
    printf "%s[?]%s %s [y/N]: " "$_C_YELLOW" "$_C_RESET" "$prompt"
    read -r reply || return 1
    case "$reply" in
        y|Y|yes|YES) return 0 ;;
        *)           return 1 ;;
    esac
}

# --------------------------------------------------------------------------
# Debug flag handling
# --------------------------------------------------------------------------
# Each script can call: parse_debug_flag "$@"
# If the user passed --debug, this enables `set -x`. We do NOT consume the
# flag from $@ - scripts that take other args should handle their own parsing
# and just check FAULT_DEBUG=1 themselves.
parse_debug_flag() {
    for arg in "$@"; do
        case "$arg" in
            --debug)
                export FAULT_DEBUG=1
                set -x
                log_warn "Debug mode enabled (set -x)"
                ;;
        esac
    done
}

# --------------------------------------------------------------------------
# Constants - account IDs and regions
# --------------------------------------------------------------------------
# These are written here so every script uses the same expectations.
# bjs1 = ychchen-bjs1 (Beijing, cn-north-1)
# china = ychchen-china (Ningxia, cn-northwest-1)
#
# Account IDs are NOT hard-coded here - validate_profile() can be called with
# an empty expected_account to skip the account check, or callers can pass
# the expected ID. We treat IDs as runtime-discoverable.
export FAULT_BJS1_PROFILE="${FAULT_BJS1_PROFILE:-ychchen-bjs1}"
export FAULT_BJS1_REGION="${FAULT_BJS1_REGION:-cn-north-1}"
export FAULT_CHINA_PROFILE="${FAULT_CHINA_PROFILE:-ychchen-china}"
export FAULT_CHINA_REGION="${FAULT_CHINA_REGION:-cn-northwest-1}"

# Resource names - keep aligned with infra/ terraform
export FAULT_BJS1_RDS_ID="${FAULT_BJS1_RDS_ID:-bjs-todo-db}"
export FAULT_BJS1_EKS_CTX="${FAULT_BJS1_EKS_CTX:-bjs1}"
export FAULT_BJS1_NS="${FAULT_BJS1_NS:-bjs-web}"
export FAULT_BJS1_DEPLOY="${FAULT_BJS1_DEPLOY:-todo-api}"
export FAULT_BJS1_CONTAINER="${FAULT_BJS1_CONTAINER:-todo-api}"
export FAULT_BJS1_GOOD_TAG="${FAULT_BJS1_GOOD_TAG:-v1.2.3}"
export FAULT_BJS1_BAD_TAG="${FAULT_BJS1_BAD_TAG:-v1.2.4-DOES-NOT-EXIST}"
export FAULT_BJS1_ALB_NAME="${FAULT_BJS1_ALB_NAME:-bjs-web-alb}"

export FAULT_CHINA_S3_OUTPUT_PREFIX="${FAULT_CHINA_S3_OUTPUT_PREFIX:-china-data-output}"
export FAULT_CHINA_ECS_CLUSTER="${FAULT_CHINA_ECS_CLUSTER:-china-data}"
export FAULT_CHINA_ECS_ETL_SERVICE="${FAULT_CHINA_ECS_ETL_SERVICE:-etl-worker}"
export FAULT_CHINA_DDB_TABLE="${FAULT_CHINA_DDB_TABLE:-etl-state}"
export FAULT_CHINA_LAMBDA_TRIGGER="${FAULT_CHINA_LAMBDA_TRIGGER:-etl-trigger}"
export FAULT_CHINA_SQS_NAME="${FAULT_CHINA_SQS_NAME:-etl-jobs}"

export FAULT_BJS1_DEMO_USER="${FAULT_BJS1_DEMO_USER:-bjs-demo-rotation-test}"
export FAULT_BJS1_BROKEN_ROLE="${FAULT_BJS1_BROKEN_ROLE:-bjs-cross-partition-test-role}"

export BJS_WEB_URL="${BJS_WEB_URL:-https://bjs-web.yingchu.cloud}"

# Where to write generated demo metadata that other scripts may need to read.
# Compute relative to this file so every script gets the same path.
_FAULTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export FAULT_METADATA_DIR="${_FAULTS_DIR}"
unset _FAULTS_DIR

# end of common.sh
