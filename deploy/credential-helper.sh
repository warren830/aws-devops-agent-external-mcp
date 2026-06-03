#!/bin/bash
# credential-helper.sh — AWS credential_process for Roles Anywhere + Hub AssumeRole
#
# Flow:
#   1. Use aws_signing_helper to get Hub credentials via X.509 cert
#   2. Use Hub credentials to AssumeRole into the target spoke account
#   3. Output credentials in credential_process JSON format
#
# Required env vars:
#   RA_CERT_PATH          — path to client certificate PEM
#   RA_KEY_PATH           — path to client private key PEM
#   RA_TRUST_ANCHOR_ARN   — Roles Anywhere Trust Anchor ARN
#   RA_PROFILE_ARN        — Roles Anywhere Profile ARN
#   RA_HUB_ROLE_ARN       — Hub Role ARN
#   RA_SPOKE_ROLE_ARN     — Target spoke account Role ARN
#   RA_REGION             — China region for Roles Anywhere endpoint
#   RA_EXTERNAL_ID        — External ID for AssumeRole (default: mcp-bridge)

set -euo pipefail

: "${RA_CERT_PATH:?Required}"
: "${RA_KEY_PATH:?Required}"
: "${RA_TRUST_ANCHOR_ARN:?Required}"
: "${RA_PROFILE_ARN:?Required}"
: "${RA_HUB_ROLE_ARN:?Required}"
: "${RA_SPOKE_ROLE_ARN:?Required}"
: "${RA_REGION:?Required}"
RA_EXTERNAL_ID="${RA_EXTERNAL_ID:-mcp-bridge}"

# Recursion guard: when invoked as the SDK's credential_process, this script
# inherits AWS_PROFILE/AWS_CONFIG_FILE from the MCP server. The inner `aws
# sts assume-role` below would re-resolve that profile → re-invoke this script
# → infinite loop. Unset them so the inner aws only sees the explicit Hub
# credentials we export from aws_signing_helper.
unset AWS_PROFILE AWS_CONFIG_FILE

HUB_CREDS=$(aws_signing_helper credential-process \
  --certificate "$RA_CERT_PATH" \
  --private-key "$RA_KEY_PATH" \
  --trust-anchor-arn "$RA_TRUST_ANCHOR_ARN" \
  --profile-arn "$RA_PROFILE_ARN" \
  --role-arn "$RA_HUB_ROLE_ARN" \
  --region "$RA_REGION")

export AWS_ACCESS_KEY_ID=$(echo "$HUB_CREDS" | jq -r '.AccessKeyId')
export AWS_SECRET_ACCESS_KEY=$(echo "$HUB_CREDS" | jq -r '.SecretAccessKey')
export AWS_SESSION_TOKEN=$(echo "$HUB_CREDS" | jq -r '.SessionToken')

SPOKE_CREDS=$(aws sts assume-role \
  --role-arn "$RA_SPOKE_ROLE_ARN" \
  --role-session-name "mcp-bridge-$(date +%s)" \
  --external-id "$RA_EXTERNAL_ID" \
  --duration-seconds 3600 \
  --region "$RA_REGION" \
  --output json)

cat <<EOF
{
  "Version": 1,
  "AccessKeyId": $(echo "$SPOKE_CREDS" | jq '.Credentials.AccessKeyId'),
  "SecretAccessKey": $(echo "$SPOKE_CREDS" | jq '.Credentials.SecretAccessKey'),
  "SessionToken": $(echo "$SPOKE_CREDS" | jq '.Credentials.SessionToken'),
  "Expiration": $(echo "$SPOKE_CREDS" | jq '.Credentials.Expiration')
}
EOF
