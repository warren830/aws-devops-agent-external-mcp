# Roles Anywhere 部署记录（2026-05-30）

本次部署：彻底清除旧 AK/SK ECS 方案 → 用 IAM Roles Anywhere 重建。

---

## 账号规划

| 角色 | 账号 ID | 区域 | Profile | 说明 |
|------|---------|------|---------|------|
| **全球 ECS 宿主** | `<GLOBAL_ACCOUNT_ID>` | us-east-1 | `default` | ECS Fargate 运行 MCP Server |
| **Hub + Spoke 1** | `<CN_NW_ACCOUNT_ID>` | cn-northwest-1 | `cn-nw-profile` | Trust Anchor + Hub Role + Spoke Role |
| **Spoke 2** | `<CN_N_ACCOUNT_ID>` | cn-north-1 | `cn-n-profile` | Spoke Role（被 Hub AssumeRole） |

信任链：
```
ECS (us-east-1, <GLOBAL_ACCOUNT_ID>)
    │ X.509 client cert
    ▼
Roles Anywhere endpoint (cn-northwest-1, <CN_NW_ACCOUNT_ID>)
    │ Hub 临时凭证
    ▼
sts:AssumeRole (ExternalId=mcp-bridge)
    ├─→ Spoke 1: arn:aws-cn:iam::<CN_NW_ACCOUNT_ID>:role/mcp-spoke-readonly (cn-northwest-1)
    └─→ Spoke 2: arn:aws-cn:iam::<CN_N_ACCOUNT_ID>:role/mcp-spoke-readonly (cn-north-1)
```

---

## Phase 1 — 清理旧部署

### 1.1 Terraform Destroy

```bash
cd ~/warren_ws/aws-devops-agent-external-mcp/terraform-ecs
terraform destroy -auto-approve
```

删除 32 个资源：ECS cluster、services、ALB、NAT Gateway、route tables、IAM roles 等。

### 1.2 删除 Private Connection

ALB Security Group `<SG_ID>` 被 VPC Lattice Resource Gateway ENI 占用，需要先在 Agent Space Console 删除 Private Connection：

1. Agent Space → Capabilities → MCP Servers → 取消勾选
2. Capability Providers → MCP Server → Delete 所有注册
3. Capability Providers → Private connections → Delete

等 ENI 释放后：
```bash
aws ec2 delete-security-group --region us-east-1 --group-id <SG_ID>
terraform state rm aws_security_group.alb
```

### 1.3 删除 AK/SK Secrets

```bash
aws secretsmanager delete-secret --region us-east-1 --secret-id /mcp/aws-cn --force-delete-without-recovery
aws secretsmanager delete-secret --region us-east-1 --secret-id /mcp/aws-cn-2 --force-delete-without-recovery
```

---

## Phase 2 — 证书生成 + Roles Anywhere 部署

### 2.1 生成证书

```bash
cd ~/warren_ws/aws-devops-agent-external-mcp/cfn
bash generate-certs.sh ~/mcp-certs
```

产出文件：

| 文件 | 有效期 | 保管 |
|------|--------|------|
| `~/mcp-certs/ca.key` | 10 年 | **离线保管（签发新 client 证书时才用）** |
| `~/mcp-certs/ca.crt` | 10 年 | 上传到 Roles Anywhere Trust Anchor |
| `~/mcp-certs/client.key` | 1 年 | Secrets Manager `/mcp/ra-key` |
| `~/mcp-certs/client.crt` | 1 年 | Secrets Manager `/mcp/ra-cert` |

证书参数：
- CA: `/CN=MCP Bridge CA/O=DevOps Agent`, RSA 4096, X.509 v3 with `CA:TRUE`
- Client: `/CN=mcp-bridge-client/O=DevOps Agent`, RSA 2048, `extendedKeyUsage=clientAuth`

### 2.2 部署 Hub（cn-northwest-1, <CN_NW_ACCOUNT_ID>）

```bash
aws cloudformation deploy \
  --template-file cfn/roles-anywhere-hub.yaml \
  --stack-name mcp-roles-anywhere-hub \
  --parameter-overrides \
    CACertificateBody="$(cat ~/mcp-certs/ca.crt)" \
    SpokeRoleArns="arn:aws-cn:iam::<CN_NW_ACCOUNT_ID>:role/mcp-spoke-readonly,arn:aws-cn:iam::<CN_N_ACCOUNT_ID>:role/mcp-spoke-readonly" \
  --capabilities CAPABILITY_NAMED_IAM \
  --region cn-northwest-1 \
  --profile cn-nw-profile
```

Hub Stack 输出：

| Output | Value |
|--------|-------|
| TrustAnchorArn | `arn:aws-cn:rolesanywhere:cn-northwest-1:<CN_NW_ACCOUNT_ID>:trust-anchor/<TRUST_ANCHOR_ID>` |
| ProfileArn | `arn:aws-cn:rolesanywhere:cn-northwest-1:<CN_NW_ACCOUNT_ID>:profile/<PROFILE_ID>` |
| HubRoleArn | `arn:aws-cn:iam::<CN_NW_ACCOUNT_ID>:role/mcp-roles-anywhere-hub` |

Hub 创建的资源：
- **Trust Anchor** `mcp-bridge-ca` — 信任 CA 证书签发的所有 client cert
- **Profile** `mcp-bridge-profile` — 限定可使用的 Role 列表 + session duration
- **Hub Role** `mcp-roles-anywhere-hub` — trust policy 只允许 Roles Anywhere service assume

### 2.3 部署 Spoke 1（cn-northwest-1, <CN_NW_ACCOUNT_ID> — 与 Hub 同账号）

```bash
aws cloudformation deploy \
  --template-file cfn/roles-anywhere-spoke.yaml \
  --stack-name mcp-spoke-role \
  --parameter-overrides HubRoleArn="arn:aws-cn:iam::<CN_NW_ACCOUNT_ID>:role/mcp-roles-anywhere-hub" \
  --capabilities CAPABILITY_NAMED_IAM \
  --region cn-northwest-1 \
  --profile cn-nw-profile
```

### 2.4 部署 Spoke 2（cn-north-1, <CN_N_ACCOUNT_ID>）

```bash
aws cloudformation deploy \
  --template-file cfn/roles-anywhere-spoke.yaml \
  --stack-name mcp-spoke-role \
  --parameter-overrides HubRoleArn="arn:aws-cn:iam::<CN_NW_ACCOUNT_ID>:role/mcp-roles-anywhere-hub" \
  --capabilities CAPABILITY_NAMED_IAM \
  --region cn-north-1 \
  --profile cn-n-profile
```

Spoke Role 的 trust policy：
```json
{
  "Effect": "Allow",
  "Principal": { "AWS": "arn:aws-cn:iam::<CN_NW_ACCOUNT_ID>:role/mcp-roles-anywhere-hub" },
  "Action": "sts:AssumeRole",
  "Condition": { "StringEquals": { "sts:ExternalId": "mcp-bridge" } }
}
```

### 2.5 存证书到 Secrets Manager（us-east-1）

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

实际 ARN（含随机后缀）：
- cert: `arn:aws:secretsmanager:us-east-1:<GLOBAL_ACCOUNT_ID>:secret:/mcp/ra-cert-XXXXXX`
- key: `arn:aws:secretsmanager:us-east-1:<GLOBAL_ACCOUNT_ID>:secret:/mcp/ra-key-XXXXXX`

---

## Phase 3 — ECS Fargate 重建（已完成 ✅）

### 3.1 更新 terraform.tfvars

核心改动：去掉 `secret_arn`（AK/SK 模式），加 `roles_anywhere` 全局块和每个 account 的 `auth_mode` + `spoke_role_arn`。

**改之前**（AK/SK 模式）：
```hcl
accounts = {
  aws-cn = {
    host       = "aws-cn.example.cloud"
    aws_region = "cn-northwest-1"
    secret_arn = "arn:aws:secretsmanager:us-east-1:<GLOBAL_ACCOUNT_ID>:secret:/mcp/aws-cn-XXXXXX"
  }
}
```

**改之后**（Roles Anywhere 模式）：
```hcl
roles_anywhere = {
  cert_secret_arn  = "arn:aws:secretsmanager:us-east-1:<GLOBAL_ACCOUNT_ID>:secret:/mcp/ra-cert-XXXXXX"
  key_secret_arn   = "arn:aws:secretsmanager:us-east-1:<GLOBAL_ACCOUNT_ID>:secret:/mcp/ra-key-XXXXXX"
  trust_anchor_arn = "arn:aws-cn:rolesanywhere:cn-northwest-1:<CN_NW_ACCOUNT_ID>:trust-anchor/<TRUST_ANCHOR_ID>"
  profile_arn      = "arn:aws-cn:rolesanywhere:cn-northwest-1:<CN_NW_ACCOUNT_ID>:profile/<PROFILE_ID>"
  hub_role_arn     = "arn:aws-cn:iam::<CN_NW_ACCOUNT_ID>:role/mcp-roles-anywhere-hub"
  region           = "cn-northwest-1"
}

accounts = {
  aws-cn = {
    host           = "aws-cn.example.cloud"
    aws_region     = "cn-northwest-1"
    auth_mode      = "roles_anywhere"
    spoke_role_arn = "arn:aws-cn:iam::<CN_NW_ACCOUNT_ID>:role/mcp-spoke-readonly"
  }

  aws-cn-2 = {
    host           = "aws-cn-2.example.cloud"
    aws_region     = "cn-north-1"
    auth_mode      = "roles_anywhere"
    spoke_role_arn = "arn:aws-cn:iam::<CN_N_ACCOUNT_ID>:role/mcp-spoke-readonly"
    use_entrypoint = true
    eks_cluster    = "bjs-web"
    eks_region     = "cn-north-1"
  }
}
```

Terraform 代码本身不需要修改 — `ecs.tf`、`secrets.tf`、`iam.tf` 已经内置了 `auth_mode` 条件分支。

### 3.2 Terraform Apply

```bash
cd terraform-ecs/
terraform apply -auto-approve
```

创建了 34 个资源（从空 state 全新创建）：
- ECS Cluster `mcp`
- 2 个 ECS Service（`mcp-aws-cn`、`mcp-aws-cn-2`）
- Internal ALB `mcp-alb` + HTTPS listener + 2 个 host-based routing rules
- NAT Gateway + IGW + Route Tables
- Security Groups（ALB + Tasks）
- IAM Roles（Execution + Task）
- ECR Repositories（`mcp-aws`、`mcp-aliyun`）
- CloudWatch Log Groups

关键输出：
```
alb_dns_name = "<ALB_DNS_NAME>"
vpc_id       = "<VPC_ID>"
```

### 3.3 Build + Push Docker 镜像

ECS Service 创建后 task 会因为 ECR 仓库为空而失败。需要 build `Dockerfile.ra` 镜像并 push。

```bash
# Login to ECR
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin <GLOBAL_ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com

# Build Roles Anywhere image（注意用 Dockerfile.ra 不是 Dockerfile）
docker build --platform linux/amd64 \
  -t <GLOBAL_ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/mcp-aws:latest \
  -f deploy/Dockerfile.ra .

# Push
docker push <GLOBAL_ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/mcp-aws:latest
```

**踩坑记录**：Docker Desktop 被企业策略锁住（Sign in required for [amazonians] org），
改用 `finch` 或等 Docker Desktop 登录后重试。最终 `docker build` + `docker push` 成功。

镜像 digest: `sha256:f94d76f102f06dd1083a27d20b84f082a4f8247418cb709285c4af8bfca6d817`

### 3.4 Force Redeploy ECS Services

```bash
aws ecs update-service --cluster mcp --service mcp-aws-cn --force-new-deployment --region us-east-1
aws ecs update-service --cluster mcp --service mcp-aws-cn-2 --force-new-deployment --region us-east-1
```

### 3.5 验证

**ECS Service 状态**：
```
| desired |     name       |  running  |
|  1      |  mcp-aws-cn    |  1        |
|  1      |  mcp-aws-cn-2  |  1        |
```

**Target Group Health**：
```
mcp-aws-cn:   healthy
mcp-aws-cn-2: healthy
```

**容器日志确认 Roles Anywhere 凭证获取成功**：
```
[entrypoint-ra] Fetching credentials via Roles Anywhere...
[entrypoint-ra] Credentials acquired, expires: 2026-05-30T05:41:22Z
```

```
Starting MCP server 'AWS-API-MCP' with transport 'streamable-http' (stateless) on http://0.0.0.0:8000/mcp
```

### 3.6 DevOps Agent 配置（Console 手工）

#### Private Connection 表单（Capability Providers → Private connections → Create）

| 字段 | 填什么 | 说明 |
|------|--------|------|
| **Name** | `mcp-alb` | |
| **VPC** | `<VPC_ID>` | ECS 所在 VPC |
| **Subnets** | `<SUBNET_ID>`, `<SUBNET_ID>` | 两个 private subnet |
| **IP address type** | `IPv4` | |
| **Security groups** | `<SG_ID>` | ALB 的 SG（name=`mcp-alb`） |
| **Host address** | `<ALB_DNS_NAME>` | ALB AWS DNS 名，**不是** example.cloud |
| **DNS resolution** | `Public` | ⚠️ 选 Public，不是 In VPC |
| **Certificate public key** | **留空** | ⚠️ 删掉占位符整个留空（ACM 公共证书默认信任） |

⚠️ **两个高频踩坑点**：
- **DNS resolution = Public**：ALB 的 `*.elb.amazonaws.com` 是公网可解析的（解析出私有 IP，但 DNS 查询走公网）。选 "In VPC (private DNS)" 反而查不到。
- **Certificate public key 留空**：用的是 ACM 公共证书（`*.example.cloud`），Lattice 默认信任公共 CA。填占位符文本会导致 TLS 握手失败。该字段只有自签证书/私有 CA 才需要填。

点 Create 后等 ~10 分钟变 `Completed`。

#### 注册 MCP Server（MCP Server → Register）

注册两个，分别对应两个 host。逐个走 4 步向导。

**Step 1 — MCP server details**

| 字段 | aws-cn | aws-cn-2 |
|------|--------|----------|
| **Name** | `aws-cn-mcp` | `aws-cn-2-mcp` |
| **Endpoint URL** | `https://aws-cn.example.cloud/mcp` | `https://aws-cn-2.example.cloud/mcp` |
| **Description** | `AWS China cn-northwest-1 via Roles Anywhere` | `AWS China cn-north-1 via Roles Anywhere` |
| **Enable Dynamic Client Registration** | ❌ 不勾 | ❌ 不勾 |
| **Connect to endpoint using a private connection** | ✅ 勾上 → 选 `mcp-alb` | ✅ 勾上 → 选 `mcp-alb` |
| **Encryption key type** | `AWS owned key` | `AWS owned key` |

⚠️ **关键点**：
- **必须勾 "Connect using a private connection"**：`aws-cn.example.cloud` 解析的是 ALB 私有 IP（10.42.x.x），不走 Private Connection 经公网根本到不了。
- **Endpoint 用域名（不是 ALB DNS）**：与 Private Connection 的 Host address 相反。Private Connection 的 Host address 填 ALB DNS（Lattice 做 DNS lookup 用）；MCP Server endpoint 填 `*.example.cloud`（ALB 用 host header 做 routing 区分两个账号）。
- **两个 MCP Server 复用同一个 Private Connection `mcp-alb`**：一条 Lattice 连接承载多 host。

**Step 2/3 — Authorization**

MCP Server 是 `AUTH_TYPE=no-auth`，但 DevOps Agent 向导要求填认证。选 API Key 模式 + 任意 dummy 值即可（后端不校验）。

**Step 4 — Review and submit** → 提交。

#### Agent Space → Capabilities → MCP Servers → Add

   - 勾选 `aws-cn-mcp` + `aws-cn-2-mcp` → Allow all tools → Save

---

## 部署完成后的关键资源 ID 速查（本次实际值）

```
VPC:            <VPC_ID>
Private subnets: <SUBNET_ID>, <SUBNET_ID>
ALB SG:         <SG_ID>  (name=mcp-alb)
ALB DNS:        <ALB_DNS_NAME>
ECR (aws):      <GLOBAL_ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/mcp-aws
```

---

## Phase 4 — Bug 修复：凭证 1 小时后过期（RequestExpired）

### 症状

部署次日，在 Agent 里调用 `aws ec2 describe-vpcs --region cn-northwest-1` 报错：

```json
{
  "error": "An error occurred (RequestExpired) when calling the DescribeVpcs operation: Request has expired.",
  "error_code": "RequestExpired"
}
```

ECS service 显示 healthy、启动日志正常，但运行约 1 小时后所有 AWS API 调用全部 `RequestExpired`。

### 根因

旧版 `entrypoint-ra.sh` 用的是「**环境变量注入 + 后台刷新循环**」模式，两者互相矛盾：

```bash
# 启动时把凭证塞进环境变量，然后 exec 启动 MCP server
export AWS_ACCESS_KEY_ID=$(echo "$CREDS" | jq -r '.AccessKeyId')
exec python -m awslabs.aws_api_mcp_server.server

# 后台循环每 55 分钟刷新，写到一个文件
(while true; do sleep 3300; NEW=$(/app/credential-helper.sh); echo "$NEW" > /tmp/ra-credentials.json; done) &
```

**关键缺陷**：运行中进程的环境变量无法被外部修改。MCP server 在 `exec` 那一刻就把
`AWS_ACCESS_KEY_ID` 冻结了。后台循环把新凭证写到 `/tmp/ra-credentials.json`，但
**没有任何代码读这个文件** —— MCP server 只认启动时的环境变量。1 小时后首个临时
token 过期，server 还在用它 → `RequestExpired`。日志里的 "Credentials refreshed"
是自欺欺人，刷新的凭证根本没被使用。

### 修复

改用 AWS SDK 原生的 `credential_process` 机制 —— `credential-helper.sh` 的输出
本来就是为此设计的标准 JSON 格式（`Version`/`AccessKeyId`/`SecretAccessKey`/
`SessionToken`/`Expiration`）。

**改动 1 — `deploy/entrypoint-ra.sh`**：删掉 env 注入和后台循环，改为写
`AWS_CONFIG_FILE` 注册 credential_process：

```bash
export AWS_CONFIG_FILE=/app/certs/aws-config
export AWS_PROFILE=ra
cat > "$AWS_CONFIG_FILE" <<EOF
[profile ra]
credential_process = /app/credential-helper.sh
EOF

# Fail fast：启动前先验证 helper 能跑通
if /app/credential-helper.sh > /dev/null 2>&1; then
  echo "[entrypoint-ra] Initial credential fetch OK."
else
  echo "[entrypoint-ra] FATAL: credential-helper.sh failed." >&2
  exit 1
fi
```

botocore 在每次 API 调用前检查缓存凭证的 `Expiration`，临近过期自动重新 exec
helper —— 惰性刷新，无后台线程，进程活着就能持续刷新。

**改动 2 — `deploy/credential-helper.sh`**：加递归守卫。helper 作为
credential_process 被调用时会继承 `AWS_PROFILE=ra`，其内部的 `aws sts assume-role`
会再次解析该 profile → 再调 helper → 无限递归。在调内部 `aws` 前 unset：

```bash
# Recursion guard
unset AWS_PROFILE AWS_CONFIG_FILE
```

只靠 `aws_signing_helper` 显式 export 的 Hub 凭证（env 变量优先级高于 profile）跑
assume-role。

### 重新部署

```bash
# rebuild + push（注意 ECR token 1h 过期，push 前重新 login）
docker build --platform linux/amd64 -t <GLOBAL_ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/mcp-aws:latest -f deploy/Dockerfile.ra .
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin <GLOBAL_ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com
docker push <GLOBAL_ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/mcp-aws:latest

# force redeploy
aws ecs update-service --cluster mcp --service mcp-aws-cn   --force-new-deployment --region us-east-1
aws ecs update-service --cluster mcp --service mcp-aws-cn-2 --force-new-deployment --region us-east-1
```

### 验证

新版启动日志（确认修复生效的标志）：

```
[entrypoint-ra] credential_process configured (profile=ra); SDK will fetch + auto-refresh.
[entrypoint-ra] Initial credential fetch OK.
Starting MCP server 'AWS-API-MCP' with transport 'streamable-http' (stateless) on http://0.0.0.0:8000/mcp
```

⚠️ **此修复对 Agent Space 完全透明** —— 只改容器内部逻辑，endpoint / Private
Connection / MCP Server 注册都不变，无需在 Agent Space 重新配置。

---

## 日常运维备忘

### 加新 Spoke 账号

1. 新账号部署 `cfn/roles-anywhere-spoke.yaml`
2. 更新 Hub 的 `SpokeRoleArns` 参数（加逗号分隔的新 ARN）
3. `terraform.tfvars` 加 entry → `terraform apply`

### 证书轮换（每年一次，client.crt 到期前）

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

# 重启 ECS 让容器拿到新证书
aws ecs update-service --cluster mcp --service mcp-aws-cn --force-new-deployment --region us-east-1
aws ecs update-service --cluster mcp --service mcp-aws-cn-2 --force-new-deployment --region us-east-1
```

### 紧急断连

| 操作 | 命令 | 生效时间 |
|------|------|---------|
| 吊销单张证书 | 上传 CRL 到 Trust Anchor | 秒级 |
| 断开所有连接 | `aws rolesanywhere disable-trust-anchor --trust-anchor-id 24dbfa91-...` | 秒级 |
| 断开单个 Spoke | 删除对应 Spoke 的 CFN stack | 分钟级 |

---

## 关键 ARN 速查

```
# Trust Anchor
arn:aws-cn:rolesanywhere:cn-northwest-1:<CN_NW_ACCOUNT_ID>:trust-anchor/<TRUST_ANCHOR_ID>

# Profile
arn:aws-cn:rolesanywhere:cn-northwest-1:<CN_NW_ACCOUNT_ID>:profile/<PROFILE_ID>

# Hub Role
arn:aws-cn:iam::<CN_NW_ACCOUNT_ID>:role/mcp-roles-anywhere-hub

# Spoke Roles
arn:aws-cn:iam::<CN_NW_ACCOUNT_ID>:role/mcp-spoke-readonly   (Spoke 1, cn-northwest-1)
arn:aws-cn:iam::<CN_N_ACCOUNT_ID>:role/mcp-spoke-readonly   (Spoke 2, cn-north-1)

# Secrets Manager (us-east-1)
arn:aws:secretsmanager:us-east-1:<GLOBAL_ACCOUNT_ID>:secret:/mcp/ra-cert-XXXXXX
arn:aws:secretsmanager:us-east-1:<GLOBAL_ACCOUNT_ID>:secret:/mcp/ra-key-XXXXXX
```
