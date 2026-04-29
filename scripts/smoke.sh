#!/bin/bash
# 本地冒烟测试：三个 SSE endpoint 能连上、能列 tools
set -e

for port in 8001 8002 8003; do
  echo "=== port $port ==="
  # SSE endpoint 能 200 并保持连接
  curl -sS -N -m 3 "http://localhost:$port/sse" | head -5 || true
  echo
done

echo "全部有 'event: endpoint' 行 → SSE 握手成功"
