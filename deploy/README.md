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
- **副本数**: 每个服务 2 副本，带 CPU/内存 request+limit；`cn-eks-kubectl` 单副本（kubeconfig 在 emptyDir，多副本无共享状态问题但 initContainer 会各自运行）
- **GCP 特殊**: 用官方 image `us-docker.pkg.dev/cloudrun/container/mcp`，不和 AWS/阿里云共用镜像；凭证走 Service Account JSON 挂载
- **cn-eks-kubectl 特殊**: initContainer 用 `amazon/aws-cli` 生成 kubeconfig 到 emptyDir；主容器 `ghcr.io/manusa/kubernetes-mcp-server` 通过 KUBECONFIG 环境变量读取；exec 插件（aws eks get-token）在主容器内由内置 aws CLI 执行，15 分钟自动刷新

## 凭证方案选择

> **当前 k8s.yaml 使用长期 AK/SK，仅适用于 demo/开发环境。**
> 生产部署必须根据集群条件选择以下方案之一。

### 方案 A — IRSA（推荐，适用于新建集群或已开启 OIDC 的集群）

前提：`aws iam list-open-id-connect-providers` 能找到集群的 OIDC provider。

```bash
# 1. 为 MCP pod 创建 ServiceAccount
kubectl -n mcp create serviceaccount mcp-sa

# 2. 创建 IAM Role，信任该 ServiceAccount（Terraform 推荐，见 terraform/main.tf 的 IRSA 示例）
# Role 附加最小权限策略：只读 EKS + CloudWatch + Secrets Manager read

# 3. 给 ServiceAccount 打注解
kubectl -n mcp annotate serviceaccount mcp-sa \
  eks.amazonaws.com/role-arn=arn:aws:iam::<ACCOUNT>:role/<MCP_IRSA_ROLE>

# 4. k8s.yaml 里各 Deployment 加 serviceAccountName: mcp-sa，删除 AK/SK env 注入
```

### 方案 B — AK/SK + Secrets Manager 轮换（适用于存量集群，无 OIDC provider）

用 Secrets Manager 存储 AK/SK，配置自动轮换（Lambda rotation function），
用 External Secrets Operator 把 Secret 同步到 k8s Secret，替代手动 create secret。

```bash
# 安装 ESO（已有 IRSA 配置，见 terraform/main.tf eso_irsa 模块）
helm install external-secrets external-secrets/external-secrets \
  -n external-secrets --create-namespace

# 创建 SecretStore 指向 Secrets Manager
# 创建 ExternalSecret 自动同步 mcp-creds
# AK/SK 轮换时 ESO 自动更新 k8s Secret，pod 无需重启（挂载会热更新）
```

**最小 IAM 权限**（两个方案通用，给 MCP pod 的身份只附加这些）：

```json
{
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "eks:DescribeCluster",
        "cloudwatch:GetMetricStatistics",
        "cloudwatch:DescribeAlarms",
        "logs:FilterLogEvents",
        "logs:StartQuery",
        "logs:GetQueryResults"
      ],
      "Resource": "*"
    }
  ]
}
```

> 注意：`call_aws` 工具理论上可以执行任意 AWS CLI 只读命令，建议在 IAM 策略里
> 明确拒绝高危写操作（`ec2:TerminateInstances`、`rds:DeleteDBInstance` 等），
> 实现双重防护。

### Demo/开发环境（当前默认）

```bash
# 仅用于非生产环境，不含 IRSA 或 Secrets Manager
kubectl -n mcp create secret generic mcp-creds \
  --from-literal=AWS_GLOBAL_AK=... \
  --from-literal=AWS_GLOBAL_SK=... \
  --from-literal=AWS_CN_AK=... \
  --from-literal=AWS_CN_SK=... \
  --from-literal=ALIYUN_AK=... \
  --from-literal=ALIYUN_SK=... \
  --from-literal=GCP_PROJECT_ID=...

kubectl -n mcp create secret generic gcp-sa-key --from-file=key.json=./gcp-sa-key.json
```

## cn-eks-kubectl 使用前提

`AWS_CN_AK` 对应的 IAM 身份需要 `eks:DescribeCluster` 权限（见上方最小权限策略）。

同时 EKS 集群的 `aws-auth` ConfigMap 需要映射该身份到 Kubernetes RBAC。
**建议映射到只读组，不要用 `system:masters`**（见 P3 Terraform 化说明）：

```yaml
# 推荐：自定义只读 ClusterRole，而非 system:masters
mapUsers: |
  - userarn: arn:aws-cn:iam::107422471498:user/<cn-mcp-user>
    username: cn-mcp-user
    groups:
      - mcp-readonly   # 绑定只有 get/list/watch 的 ClusterRole
```
