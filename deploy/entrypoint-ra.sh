#!/bin/bash
# entrypoint-ra.sh — Container entrypoint for Roles Anywhere auth mode.
#
# If RA_SPOKE_ROLE_ARN is set, uses credential-helper.sh to obtain
# temporary credentials before starting the MCP server.
# Otherwise falls back to ambient credentials (AK/SK from env/secrets).
set -euo pipefail

if [[ -n "${RA_SPOKE_ROLE_ARN:-}" ]]; then
  # ECS injects cert/key as env vars (from Secrets Manager).
  # Write them to files for aws_signing_helper.
  if [[ -n "${RA_CERT_PEM:-}" ]]; then
    echo "$RA_CERT_PEM" > "${RA_CERT_PATH:-/app/certs/client.crt}"
    echo "$RA_KEY_PEM" > "${RA_KEY_PATH:-/app/certs/client.key}"
    chmod 600 "${RA_KEY_PATH:-/app/certs/client.key}"
    unset RA_CERT_PEM RA_KEY_PEM
  fi

  echo "[entrypoint-ra] Fetching credentials via Roles Anywhere..."
  CREDS=$(/app/credential-helper.sh)

  export AWS_ACCESS_KEY_ID=$(echo "$CREDS" | jq -r '.AccessKeyId')
  export AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | jq -r '.SecretAccessKey')
  export AWS_SESSION_TOKEN=$(echo "$CREDS" | jq -r '.SessionToken')

  EXPIRATION=$(echo "$CREDS" | jq -r '.Expiration')
  echo "[entrypoint-ra] Credentials acquired, expires: $EXPIRATION"

  # Start background refresh loop (renew 5 min before expiry)
  (
    while true; do
      sleep 3300  # 55 minutes
      echo "[entrypoint-ra] Refreshing credentials..."
      NEW_CREDS=$(/app/credential-helper.sh 2>/dev/null) || continue
      # Write refreshed creds to a shared file the SDK can pick up
      echo "$NEW_CREDS" > /tmp/ra-credentials.json
      echo "[entrypoint-ra] Credentials refreshed at $(date -u +%FT%TZ)"
    done
  ) &
fi

# Determine which server to start
if [[ -n "${EKS_CLUSTER_NAME:-}" ]]; then
  exec python /app/entrypoint.py
else
  exec python -m awslabs.aws_api_mcp_server.server
fi
