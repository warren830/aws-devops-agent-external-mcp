# mcp-aliyun-server Helm chart

每个阿里云账号一个 Helm release。与 AWS chart 独立维护（依赖冲突 —— `alibaba-cloud-ops-mcp-server` 和 `awslabs.aws-api-mcp-server` 的 `fastmcp` 版本不兼容），但共享同一 ALB（靠 IngressGroup 合并）。

## 安装前置：构建阿里云镜像

AWS chart 用的是 `aws-devops-agent-external-mcp` 镜像，阿里云用 **另一个独立镜像** `mcp-aliyun`。首次使用先构建：

```bash
# 创 ECR 仓库
aws ecr create-repository --repository-name mcp-aliyun --region us-east-1

# 登录 + 构建 + 推送
ECR=034362076319.dkr.ecr.us-east-1.amazonaws.com/mcp-aliyun
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin 034362076319.dkr.ecr.us-east-1.amazonaws.com
docker build --platform linux/amd64 -t $ECR:latest -f deploy/Dockerfile.aliyun .
docker push $ECR:latest
```

## 安装

```bash
helm upgrade --install aliyun-prod ./chart-aliyun -f chart-aliyun/values-aliyun-prod.yaml --wait
```

## 加一个新阿里云账号

1. **凭证**：写进 K8s Secret 或 Secrets Manager（同 AWS chart 的流程）
2. **DNS**：Route53 私有 zone 加 CNAME `<name>.yingchu.cloud → ALB`
3. **values 文件**：复制 `values-aliyun-prod.yaml`，改 4 个字段（`name / host / secretKeys` 或 `secretsManagerKey` / `aliyunEnv`）
4. **部署**：`helm upgrade --install <name> ./chart-aliyun -f chart-aliyun/values-<name>.yaml --wait`
5. **DevOps Agent 注册**：跟 AWS 一样，复用现有 `mcp-alb` Private Connection

## values 字段速查

| 字段 | 必填 | 示例 | 说明 |
|---|---|---|---|
| `account.name` | ✅ | `aliyun-prod` | 资源命名前缀（`mcp-aliyun-prod`）|
| `account.host` | ✅ | `aliyun-prod.yingchu.cloud` | Ingress host 匹配 |
| `account.existingSecret` | Mode A ✅ | `mcp-creds` | 复用的 K8s Secret 名 |
| `account.secretKeys.ALIBABA_CLOUD_ACCESS_KEY_ID` | Mode A ✅ | `ALIYUN_PROD_AK` | Secret 里对应 key 名 |
| `account.secretsManagerKey` | Mode B ✅ | `/mcp/aliyun-prod` | Secrets Manager key |
| `mcpServer.aliyunEnv` | ✅ | `domestic` 或 `international` | 阿里云 API 端点类型 |
| `replicaCount` | ⚪ | `1`（默认）| ⚠️ 默认 1，等上游支持 stateless 后才能 >1 |
| `account.extraEnv` | ⚪ | - | 额外环境变量 |

## 为什么和 AWS chart 分家

| 维度 | AWS chart | Aliyun chart |
|---|---|---|
| 底层包 | `awslabs.aws-api-mcp-server` | `alibaba-cloud-ops-mcp-server` |
| 容器镜像 | `aws-devops-agent-external-mcp` | `mcp-aliyun`（另一个 ECR 仓库）|
| Transport 配置方式 | 环境变量 `AWS_API_MCP_*` | CLI flag `--transport ...` |
| Stateless HTTP | 支持（`AWS_API_MCP_STATELESS_HTTP=true`）| ⚠️ 不支持 |
| 凭证 env var | `AWS_ACCESS_KEY_ID` | `ALIBABA_CLOUD_ACCESS_KEY_ID` |
| 区域切换 | `AWS_DEFAULT_REGION` | `--env domestic/international` |

统一成一个 chart 要写一堆 `{{ if .aws }} ... {{ else }} ...` 条件，读起来脑裂，不如两份 chart 独立演进。

## 已知限制

- **replicaCount 只能 1**：`alibaba-cloud-ops-mcp-server 0.9.27` 没暴露 stateless HTTP 开关。多副本会触发 session split（"Session not found" 错误）。等上游加 `--stateless` CLI flag 或 `ALIBABA_CLOUD_MCP_STATELESS_HTTP` env var 支持。
- **版本 pin 在 `deploy/Dockerfile.aliyun`**：升级要改 `ARG ALIYUN_MCP_VERSION` + 重新构建推镜像。
- **International vs Domestic 二选一**：一个 pod 只能服务一种。跨类型混管得开两个 chart release。
