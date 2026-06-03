# IAM Roles Anywhere 部署指南

用 X.509 证书替代长期 AK/SK，实现零密钥多账号认证。

## 前置条件

- ECS Fargate 方案已部署（[README 快速开始](./README.md#快速开始)）
- 至少一个中国区 AWS 账号
- 本地已安装 `openssl`、`aws` CLI

## 架构概览

```
MCP Server (us-east-1 ECS)
    │ X.509 cert
    ▼
Roles Anywhere endpoint (cn-northwest-1, Hub 账号)
    │ Hub 临时凭证
    ▼
sts:AssumeRole (ExternalId=mcp-bridge)
    │
    ├─→ Spoke A (cn-northwest-1) ReadOnlyAccess
    ├─→ Spoke B (cn-north-1)     ReadOnlyAccess
    └─→ Spoke C (cn-northwest-1) CustomPolicy
```

一张证书 → 一个 Hub → N 个 Spoke，加账号只需在新 Spoke 部署一个 Role。

---

## Step 1: 生成证书

```bash
cd cfn/
./generate-certs.sh ~/mcp-certs
```

产出四个文件：

| 文件 | 用途 | 保管方式 |
|------|------|---------|
| `ca.crt` | 上传到 Roles Anywhere Trust Anchor | 可公开 |
| `ca.key` | 签发新客户端证书 | **离线保管（HSM/Vault）** |
| `client.crt` | 存入 Secrets Manager，ECS 容器启动时使用 | Secrets Manager |
| `client.key` | 存入 Secrets Manager，ECS 容器启动时使用 | Secrets Manager |

---

## Step 2: 部署 Hub 账号

选一个中国区账号作为 Hub（建议用管理账号或安全账号）。

```bash
# 确认 Spoke Role ARN 列表（逗号分隔）
SPOKE_ARNS="arn:aws-cn:iam::SPOKE_A_ID:role/mcp-spoke-readonly,arn:aws-cn:iam::SPOKE_B_ID:role/mcp-spoke-readonly"

aws cloudformation deploy \
  --template-file cfn/roles-anywhere-hub.yaml \
  --stack-name mcp-roles-anywhere-hub \
  --parameter-overrides \
    CACertificateBody="$(cat ~/mcp-certs/ca.crt)" \
    SpokeRoleArns="$SPOKE_ARNS" \
  --capabilities CAPABILITY_NAMED_IAM \
  --region cn-northwest-1 \
  --profile <your-hub-profile>
```

记录输出（后续步骤需要）：

```bash
TRUST_ANCHOR_ARN=$(aws cloudformation describe-stacks \
  --stack-name mcp-roles-anywhere-hub --region cn-northwest-1 --profile <hub> \
  --query 'Stacks[0].Outputs[?OutputKey==`TrustAnchorArn`].OutputValue' --output text)

PROFILE_ARN=$(aws cloudformation describe-stacks \
  --stack-name mcp-roles-anywhere-hub --region cn-northwest-1 --profile <hub> \
  --query 'Stacks[0].Outputs[?OutputKey==`ProfileArn`].OutputValue' --output text)

HUB_ROLE_ARN=$(aws cloudformation describe-stacks \
  --stack-name mcp-roles-anywhere-hub --region cn-northwest-1 --profile <hub> \
  --query 'Stacks[0].Outputs[?OutputKey==`HubRoleArn`].OutputValue' --output text)
```

---

## Step 3: 部署 Spoke 账号

在每个目标中国区账号里运行：

```bash
aws cloudformation deploy \
  --template-file cfn/roles-anywhere-spoke.yaml \
  --stack-name mcp-spoke-role \
  --parameter-overrides HubRoleArn="$HUB_ROLE_ARN" \
  --capabilities CAPABILITY_NAMED_IAM \
  --region <spoke-region> \
  --profile <spoke-profile>
```

如果 Hub 和 Spoke 是同一个账号，也需要部署（Hub Role assume 自己账号的 Spoke Role）。

**企业合规**：如果组织要求 PermissionsBoundary，加参数：

```bash
--parameter-overrides \
  HubRoleArn="$HUB_ROLE_ARN" \
  PermissionsBoundary="arn:aws-cn:iam::SPOKE:policy/org-boundary"
```

---

## Step 4: 存证书到 Secrets Manager

在 ECS 所在的全球区账号（`us-east-1`）：

```bash
aws secretsmanager create-secret \
  --name /mcp/ra-cert \
  --secret-string file://~/mcp-certs/client.crt \
  --region us-east-1

aws secretsmanager create-secret \
  --name /mcp/ra-key \
  --secret-string file://~/mcp-certs/client.key \
  --region us-east-1
```

获取完整 ARN（含随机后缀）：

```bash
CERT_ARN=$(aws secretsmanager describe-secret --secret-id /mcp/ra-cert --region us-east-1 --query 'ARN' --output text)
KEY_ARN=$(aws secretsmanager describe-secret --secret-id /mcp/ra-key --region us-east-1 --query 'ARN' --output text)
```

---

## Step 5: 构建 Roles Anywhere 镜像

```bash
# 从项目根目录
docker build --platform linux/amd64 \
  -t <ECR_URL>:latest \
  -f deploy/Dockerfile.ra .

# 推送
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin <ACCOUNT>.dkr.ecr.us-east-1.amazonaws.com
docker push <ECR_URL>:latest
```

`Dockerfile.ra` 相对于原始 `Dockerfile` 额外包含：
- `aws_signing_helper` — Roles Anywhere 官方 credential helper
- `awscli` + `jq` — 用于 AssumeRole 和 JSON 解析
- `credential-helper.sh` + `entrypoint-ra.sh` — 凭证获取逻辑

**凭证刷新机制**：`entrypoint-ra.sh` 把 `credential-helper.sh` 注册为 AWS SDK 的
`credential_process`（写入 `AWS_CONFIG_FILE`，`AWS_PROFILE=ra`）。botocore 在每次
API 调用前检查缓存凭证的 `Expiration`，临近过期自动重新调用 helper —— 惰性刷新，
无后台线程。`credential-helper.sh` 内部会 `unset AWS_PROFILE AWS_CONFIG_FILE` 防止
`aws sts assume-role` 递归解析回同一 profile。

---

## Step 6: 修改 Terraform 配置

编辑 `terraform-ecs/terraform.tfvars`：

```hcl
# ===== 新增：Roles Anywhere 全局配置 =====
roles_anywhere = {
  cert_secret_arn  = "arn:aws:secretsmanager:us-east-1:<GLOBAL_ACCOUNT_ID>:secret:/mcp/ra-cert-XXXXXX"
  key_secret_arn   = "arn:aws:secretsmanager:us-east-1:<GLOBAL_ACCOUNT_ID>:secret:/mcp/ra-key-XXXXXX"
  trust_anchor_arn = "arn:aws-cn:rolesanywhere:cn-northwest-1:HUB_ACCOUNT:trust-anchor/xxx"
  profile_arn      = "arn:aws-cn:rolesanywhere:cn-northwest-1:HUB_ACCOUNT:profile/yyy"
  hub_role_arn     = "arn:aws-cn:iam::HUB_ACCOUNT:role/mcp-roles-anywhere-hub"
  region           = "cn-northwest-1"
}

# ===== 修改：accounts 切换 auth_mode =====
accounts = {
  aws-cn = {
    host           = "aws-cn.example.cloud"
    aws_region     = "cn-northwest-1"
    auth_mode      = "roles_anywhere"            # 改这里
    spoke_role_arn = "arn:aws-cn:iam::SPOKE_A:role/mcp-spoke-readonly"
    # access_key / secret_key 不再需要，可以删掉
  }

  aws-cn-2 = {
    host           = "aws-cn-2.example.cloud"
    aws_region     = "cn-north-1"
    auth_mode      = "roles_anywhere"            # 改这里
    spoke_role_arn = "arn:aws-cn:iam::SPOKE_B:role/mcp-spoke-readonly"
    use_entrypoint = true
    eks_cluster    = "bjs-web"
    eks_region     = "cn-north-1"
  }
}
```

---

## Step 7: 部署

```bash
cd terraform-ecs/
terraform apply
```

Terraform 会：
- 更新 ECS Task Definition（注入 RA 环境变量 + cert/key secrets）
- 更新 IAM Policy（允许读取 cert/key secrets）
- 不再为 RA 账号创建 AK/SK 的 Secrets Manager secret
- 滚动部署新 Task

---

## Step 8: 验证

```bash
# 1. 检查 ECS 服务状态
aws ecs describe-services --cluster mcp --services mcp-aws-cn --region us-east-1 \
  --query 'services[0].{status:status,running:runningCount,desired:desiredCount}'

# 2. 查看容器日志确认凭证链路就绪
aws logs tail /ecs/mcp-aws-cn --region us-east-1 --since 5m | grep "entrypoint-ra"
# 应该看到:
#   [entrypoint-ra] credential_process configured (profile=ra); SDK will fetch + auto-refresh.
#   [entrypoint-ra] Initial credential fetch OK.

# 3. 通过 Agent 验证端到端
# 在 Operator Web App 里发: "查一下 aws-cn 的 VPC 列表"
```

---

## 日常运维

### 加新的 Spoke 账号

1. 在新账号部署 Spoke CFN：
   ```bash
   aws cloudformation deploy --template-file cfn/roles-anywhere-spoke.yaml ...
   ```

2. 更新 Hub 的 `SpokeRoleArns` 参数：
   ```bash
   aws cloudformation deploy --template-file cfn/roles-anywhere-hub.yaml \
     --parameter-overrides SpokeRoleArns="旧ARN,新ARN" ...
   ```

3. 在 `terraform.tfvars` 加 entry → `terraform apply`

### 证书轮换（每年一次）

```bash
# 用已有 CA 签新证书
openssl genrsa -out ~/mcp-certs/client-new.key 2048
openssl req -new -key ~/mcp-certs/client-new.key -out /tmp/new.csr \
  -subj "/CN=mcp-bridge-client/O=DevOps Agent"
openssl x509 -req -in /tmp/new.csr \
  -CA ~/mcp-certs/ca.crt -CAkey ~/mcp-certs/ca.key -CAcreateserial \
  -out ~/mcp-certs/client-new.crt -days 365

# 更新 Secrets Manager
aws secretsmanager update-secret-value --secret-id /mcp/ra-cert \
  --secret-string file://~/mcp-certs/client-new.crt --region us-east-1
aws secretsmanager update-secret-value --secret-id /mcp/ra-key \
  --secret-string file://~/mcp-certs/client-new.key --region us-east-1

# 重启 ECS
aws ecs update-service --cluster mcp --service mcp-aws-cn --force-new-deployment --region us-east-1
```

不需要改 Roles Anywhere 配置 — Trust Anchor 信任 CA，不是单张 cert。

### 紧急断连

| 场景 | 操作 | 生效时间 |
|------|------|---------|
| 吊销单张证书 | 上传 CRL 到 Trust Anchor | 秒级 |
| 断开所有连接 | 禁用 Trust Anchor | 秒级 |
| 断开单个 Spoke | 删除 Spoke 的 CFN stack | 分钟级 |

---

## 混合模式迁移

不需要一刀切。在同一个 `accounts` map 里混用两种模式：

```hcl
accounts = {
  # 已迁移
  aws-cn   = { auth_mode = "roles_anywhere", spoke_role_arn = "..." }
  # 还在用 AK/SK
  aws-cn-2 = { auth_mode = "ak_sk", access_key = "...", secret_key = "..." }
  # 阿里云（永远 AK/SK）
  aliyun   = { provider = "aliyun", access_key = "...", secret_key = "..." }
}
```

推荐迁移顺序：生产账号优先（安全收益最大）→ 验证稳定 → 迁移其余。

---

## Troubleshooting

| 症状 | 原因 | 解法 |
|------|------|------|
| `certificate has expired` | client.crt 过期 | 签新证书，更新 SM，重启 ECS |
| `trust anchor not found` | Trust Anchor ARN 错误或已被禁用 | 检查 ARN、确认 Trust Anchor enabled |
| `access denied` on AssumeRole | Spoke Role trust policy 不信任 Hub Role | 检查 Spoke CFN 的 `HubRoleArn` 参数 |
| `invalid external id` | ExternalId 不匹配 | 确认 terraform.tfvars 里的 `external_id` 与 Spoke trust policy 一致（默认 `mcp-bridge`） |
| `connect to endpoint failed` | ECS 容器无法访问中国区 endpoint | 确认 NAT Gateway 正常、安全组出站规则允许 443 |
| `RequestExpired`（运行 1 小时后） | 旧版用 env 注入 + 后台 refresh loop，但运行中进程的环境变量无法被修改，server 一直用首个 1h token | 已修复：改用 SDK 原生 `credential_process`（`entrypoint-ra.sh` 写 `AWS_CONFIG_FILE` + `credential_process=credential-helper.sh`），botocore 按 `Expiration` 惰性自动刷新。确保镜像是新版（含 `credential_process configured` 日志） |
