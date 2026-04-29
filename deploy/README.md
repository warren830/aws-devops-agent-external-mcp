# 部署说明

详细步骤见项目根目录 [README.md](../README.md) 的「部署到 AWS EKS」章节。

## 文件说明

| 文件 | 用途 |
|---|---|
| `Dockerfile` | 基础镜像：Node 20 + supergateway + uv（Python MCP 运行时） |
| `k8s.yaml` | 2 个 Deployment（aws-global / aws-cn）+ 2 个 Service + 内部 ALB Ingress (HTTPS) |

## 当前部署的配置

- Transport: **Streamable HTTP**（`--outputTransport streamableHttp`）
- 端点路径: `/aws-global/mcp` 和 `/aws-cn/mcp`
- ALB: 内部，仅 HTTPS:443
- 健康检查: `/healthz`
