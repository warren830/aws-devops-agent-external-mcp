# 部署说明

详细步骤见项目根目录 [README.md](../README.md) 的「部署到 AWS EKS」章节。

## 文件说明

| 文件 | 用途 |
|---|---|
| `Dockerfile` | python:3.12-slim + 预装两个 Python MCP Server（aws-api-mcp-server、alibaba-cloud-ops-mcp-server，版本 pin） |
| `k8s.yaml` | 4 个 Deployment（aws-global / aws-cn / aliyun / gcp）+ 4 个 Service + 共享 ALB Ingress |

## 当前架构要点

- **Transport**: Streamable HTTP 原生（各 MCP Server 自己实现，无 supergateway）
- **路由方式**: Host-based（按子域名分流）
- **端点路径**: 每个服务都是 `/mcp`（FastMCP 默认，不可改）
- **ALB**: 内部，仅 HTTPS:443
- **证书**: 通配符 `*.mcp.internal`（自签）
- **健康检查**: TCP probe（MCP Server 没有 `/healthz`）
- **副本数**: 每个服务 2 副本，带 CPU/内存 request+limit
- **GCP 特殊**: 用官方 image `us-docker.pkg.dev/cloudrun/container/mcp`，不和 AWS/阿里云共用镜像；凭证走 Service Account JSON 挂载

## Secret 要求

```bash
# AWS + 阿里云 AK/SK + GCP Project ID
kubectl -n mcp create secret generic mcp-creds \
  --from-literal=AWS_GLOBAL_AK=... \
  --from-literal=AWS_GLOBAL_SK=... \
  --from-literal=AWS_CN_AK=... \
  --from-literal=AWS_CN_SK=... \
  --from-literal=ALIYUN_AK=... \
  --from-literal=ALIYUN_SK=... \
  --from-literal=GCP_PROJECT_ID=...

# GCP Service Account JSON（文件挂载）
kubectl -n mcp create secret generic gcp-sa-key --from-file=key.json=./gcp-sa-key.json
```
