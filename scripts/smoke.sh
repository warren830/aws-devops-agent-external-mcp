#!/bin/bash
# Local smoke test: verify each MCP server responds to an MCP `initialize` handshake.
# Assumes `docker compose up -d` is running.
#
# Note: we POST to /mcp/ (with trailing slash) and use -L to follow 307 redirects,
# because different FastMCP versions have different slash-handling behavior.
set -e

test_mcp() {
  local name=$1 port=$2
  echo "=== $name (:$port) ==="
  curl -sS -N -L -m 10 \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -X POST "http://localhost:$port/mcp/" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}' \
    -w "\nHTTP: %{http_code}\n" \
    | head -3
  echo
}

test_mcp aws-global 8001
test_mcp aws-cn     8002
test_mcp aliyun     8003
test_mcp gcp        8004

echo "OK: every 200 response with 'serverInfo' in the payload = native streamable-http working"
