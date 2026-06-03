#!/bin/bash
# entrypoint-ra.sh — Container entrypoint for Roles Anywhere auth mode.
#
# Wires credential-helper.sh into the AWS SDK as a credential_process so the
# SDK auto-refreshes spoke credentials on expiry (reads the "Expiration" field
# and re-invokes the helper). No env-var injection, no manual refresh loop —
# a running process can't have its env vars mutated, so the old approach left
# the MCP server pinned to the first 1h token (→ RequestExpired after expiry).
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

  # Register credential-helper.sh as a credential_process. botocore invokes it
  # on demand and re-invokes automatically when the cached creds near expiry.
  export AWS_CONFIG_FILE=/app/certs/aws-config
  export AWS_PROFILE=ra
  cat > "$AWS_CONFIG_FILE" <<EOF
[profile ra]
credential_process = /app/credential-helper.sh
EOF

  echo "[entrypoint-ra] credential_process configured (profile=ra); SDK will fetch + auto-refresh."

  # Fail fast: prove the helper works before starting the server.
  if /app/credential-helper.sh > /dev/null 2>&1; then
    echo "[entrypoint-ra] Initial credential fetch OK."
  else
    echo "[entrypoint-ra] FATAL: credential-helper.sh failed. Check cert/trust-anchor/spoke-role config." >&2
    /app/credential-helper.sh || true   # re-run to surface the error in logs
    exit 1
  fi
fi

# Determine which server to start
if [[ -n "${EKS_CLUSTER_NAME:-}" ]]; then
  exec python /app/entrypoint.py
else
  exec python -m awslabs.aws_api_mcp_server.server
fi
