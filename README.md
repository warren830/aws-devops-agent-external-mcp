# aws-devops-agent-external-mcp

**中文** | [English](./README.en.md)

把 **AWS DevOps Agent** 连接到自建 MCP Server，通过 VPC Lattice Private Connection 在私网完成端到端调用。支持 **ECS Fargate**（推荐）和 **EKS** 两种部署方式。

**零业务代码** —— 所有 MCP Server 用官方包（`awslabs.aws-api-mcp-server`、`alibaba-cloud-ops-mcp-server` 等），本项目只做容器化、编排、AWS 网络接线。

> 🚀 **ECS Fargate 方案（推荐）**：一个 `terraform apply` 搞定全部，无需 K8s（见下方快速开始）
> 🔐 **IAM Roles Anywhere（企业级）**：消灭 AK/SK，证书 + 临时凭证 + Hub-Spoke 多账号 → [docs/deploy/DEPLOY-ROLES-ANYWHERE.md](./docs/deploy/DEPLOY-ROLES-ANYWHERE.md)
> 📖 **EKS 方案完整部署步骤**：[docs/legacy-eks/SETUP.md](./docs/legacy-eks/SETUP.md)
> 🐛 **踩坑故事版博客（7 个层面的故障定位）**：[docs/blog/BLOG.md](./docs/blog/BLOG.md)
> 🏗️ **多账号扩展运维指南**（Helm chart + ESO）：[docs/legacy-eks/MULTI-ACCOUNT.md](./docs/legacy-eks/MULTI-ACCOUNT.md)
> 🔥 **从零重建 runbook**（destroy 现有 + 按最新代码 Mode B 重部）：[docs/deploy/REBUILD.md](./docs/deploy/REBUILD.md)
> 📚 **完整文档索引** → [docs/README.md](./docs/README.md)

---

## 架构

```
┌──────────────────┐      ┌─────────────────┐      ┌───────────────┐       ┌─────────────────────────┐
│ AWS DevOps Agent │──────│ Private         │──────│ Internal ALB  │───┬──→│ aws-cn (Fargate/Pod)    │
│ (Agent Space)    │ VPC  │ Connection      │ 内网 │ (HTTPS:443)   │   │   └─────────────────────────┘
└──────────────────┘ Lat. │ (Resource GW)   │      │ host-based    │   │   ┌─────────────────────────┐
                          └─────────────────┘      │ routing       │   ├──→│ aws-cn-2 (Fargate/Pod)  │
                                                   └───────────────┘   │   └─────────────────────────┘
                                                          ↑            │   ┌─────────────────────────┐
                                            ACM *.example.cloud        └──→│ aliyun-prod (Fargate)   │
                                                                           └─────────────────────────┘
```

**几个关键设计决策**：

| 决策 | 原因 |
|---|---|
| **一个 ALB + host-based 路由** | 多个 MCP Server 共享一条 Private Connection，一张证书覆盖所有 |
| **公共 ACM 证书（不是自签）** | Lattice TLS 握手默认只信任公共 CA 链，自签要手动上传 PEM 麻烦且易错 |
| **原生 Streamable HTTP（不用 supergateway）** | 去掉协议桥，少一层故障面。supergateway stateless 模式还有 crash bug |
| **`AWS_API_MCP_STATELESS_HTTP=true` + 2 副本** | MCP 默认 stateful session 在多副本时会 "Session not found"。开 stateless 让任意 pod 能处理任意请求 |
| **Private Connection 的 Host address 填 ALB 的 AWS DNS 名** | 这个字段要**公网可解析**（Lattice 用它做 DNS lookup）。填私有域名会 NXDOMAIN |
| **DNS split-horizon** | `example.cloud` 公网在 Tencent DNSPod，私网在 Route53 私有 zone，各管各的 |

---

## 两种部署方案 × 两种认证模式

### 部署方案

| | **ECS Fargate（推荐）** | **EKS** |
|---|---|---|
| 部署命令 | `terraform apply`（一步） | terraform + helm×3 + kubectl（五步） |
| 月固定成本 | ~$57（NAT $32 + ALB $16 + Fargate ~$9/service） | ~$130（NAT + ALB + EKS 控制面 $72 + Node） |
| 加账号 | 改 tfvars + `terraform apply` | 写 values.yaml + `helm install` |
| 凭证管理 | Secrets Manager 直读（原生） | ESO + IRSA + ClusterSecretStore |
| 适合 | 大多数场景、没有 K8s 的团队 | 已有 EKS、需要跑十几个微服务的场景 |
| 目录 | `terraform-ecs/` | `terraform/` + `chart/` + `chart-aliyun/` |
| 博客 | 04 - ECS Fargate 轻量化 | 01 单账号 / 02 多账号 / 03 Skills 实战 |

### 认证模式

| | **AK/SK（默认）** | **IAM Roles Anywhere（企业级推荐）** |
|---|---|---|
| 凭证类型 | 长期 Access Key / Secret Key | X.509 证书 → 1h 临时凭证 |
| 泄露影响 | 永久有效直到手动轮换 | 最多 1h，可 CRL 秒级吊销 |
| 多账号凭证数 | N 对 AK/SK | 1 张证书（Hub AssumeRole 扇出） |
| 加账号 | 创建 IAM User + 存 AK/SK | 部署 Spoke CFN（1 个 Role） |
| 适合 | 快速验证、开发环境 | 生产、合规要求高的企业 |
| 配置指南 | 下方快速开始 | [docs/deploy/DEPLOY-ROLES-ANYWHERE.md](./docs/deploy/DEPLOY-ROLES-ANYWHERE.md) |

两种认证模式可以**在同一个 `accounts` map 里混用**（`auth_mode` 字段切换）。

---

## 目录

```
.
├── README.md                    ← 你在这
├── docs/                        ← 📚 文档（见 docs/README.md 索引）
│   ├── README.md                ← 文档索引
│   ├── deploy/                  ← 🔐 当前推荐部署文档
│   │   ├── DEPLOY-ROLES-ANYWHERE.md  ← IAM Roles Anywhere 部署指南
│   │   ├── DEPLOY-RA-RECORD.md       ← 真实部署日志（精确命令）
│   │   └── REBUILD.md                ← 从零重建 runbook
│   ├── legacy-eks/              ← ⚠️ 旧版 EKS 方案（推荐改用 ECS）
│   │   ├── SETUP.md                  ← EKS 方案完整配置指南
│   │   └── MULTI-ACCOUNT.md          ← EKS 多账号扩展运维（Helm + ESO）
│   └── blog/
│       └── BLOG.md                   ← 7 层故障面故事版踩坑博客
├── docker-compose.yml           ← 本地冒烟测试
├── cfn/                         ← 🔐 IAM Roles Anywhere CloudFormation
│   ├── roles-anywhere-hub.yaml  ← Hub 账号（Trust Anchor + Profile + Hub Role）
│   ├── roles-anywhere-spoke.yaml← Spoke 账号（ReadOnly Role）
│   └── generate-certs.sh        ← 一键生成 CA + client 证书
├── deploy/
│   ├── Dockerfile               ← AWS MCP 镜像（AK/SK 模式）
│   ├── Dockerfile.ra            ← AWS MCP 镜像（Roles Anywhere 模式）
│   ├── Dockerfile.aliyun        ← 阿里云 MCP 镜像
│   ├── credential-helper.sh     ← cert → Hub 凭证 → AssumeRole → Spoke 凭证
│   └── entrypoint-ra.sh         ← RA 容器启动器（证书写盘 + 注册 credential_process）
├── terraform-ecs/               ← ⭐ ECS Fargate 方案（推荐）
│   ├── main.tf                  ← Provider
│   ├── variables.tf             ← accounts map（auth_mode: ak_sk | roles_anywhere）
│   ├── network.tf               ← IGW + NAT Gateway + 路由表
│   ├── alb.tf                   ← Internal ALB + HTTPS listener
│   ├── ecs.tf                   ← ECS Cluster + for_each Services
│   ├── iam.tf                   ← Execution Role + Task Role
│   ├── secrets.tf               ← 按 auth_mode 条件创建 secret
│   ├── outputs.tf               ← ALB DNS name + DNS 操作提示
│   └── terraform.tfvars.example ← 配置模板（含两种认证模式示例）
├── terraform/                   ← EKS 方案基础设施
│   └── main.tf                  ← VPC + EKS + IRSA
├── chart/                       ← EKS 方案 Helm chart（AWS）
├── chart-aliyun/                ← EKS 方案 Helm chart（阿里云）
└── scripts/
    └── smoke.sh                 ← 本地 docker-compose 冒烟测试
```

---

## 快速开始

### 1️⃣ 本地验证（不需要 AWS 资源）

```bash
cp .env.example .env
vim .env                        # 填 AWS/aliyun 凭证

docker compose up -d
bash scripts/smoke.sh           # 对本地端口发 MCP initialize 握手
```

### 2️⃣ 部署到 AWS — ECS Fargate 方案（推荐）

只需填一个配置文件，terraform 自动创建全部资源（VPC 可选自动创建、ECR、Secrets Manager、ALB、ECS）。

```bash
cd terraform-ecs
cp terraform.tfvars.example terraform.tfvars
```

编辑 `terraform.tfvars`，填入 3 样东西：

```hcl
# 1. TLS 证书（ACM 公共证书，需提前申请好）
certificate_arn = "arn:aws:acm:us-east-1:ACCOUNT:certificate/CERT_ID"

# 2. 目标账号凭证 + 域名
accounts = {
  aws-cn = {
    host       = "aws-cn.example.com"     # 你的域名
    aws_region = "cn-northwest-1"
    access_key = "AKIA..."                # 目标账号 AK
    secret_key = "..."                    # 目标账号 SK
  }
}

# 3. VPC（可选 — 留空自动创建，已有则填 ID）
# vpc_id             = "vpc-xxx"
# public_subnet_ids  = ["subnet-aaa", "subnet-bbb"]
# private_subnet_ids = ["subnet-ccc", "subnet-ddd"]
```

一键部署：

```bash
terraform init && terraform apply    # ~3 分钟，创建全部基础设施
```

Apply 完成后推镜像（仅首次需要）：

```bash
# terraform output 会打印完整命令，以下是示例
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin <ACCOUNT>.dkr.ecr.us-east-1.amazonaws.com
docker build --platform linux/amd64 -t <ECR_URL>:latest -f deploy/Dockerfile .
docker push <ECR_URL>:latest

# 让 ECS 拉取镜像
aws ecs update-service --cluster mcp --service mcp-aws-cn --force-new-deployment
```

> 后续加账号 = 在 `terraform.tfvars` 加一个 entry + `terraform apply`，不需要再推镜像。

详见下方快速开始与 [docs/deploy/DEPLOY-ROLES-ANYWHERE.md](./docs/deploy/DEPLOY-ROLES-ANYWHERE.md)。

### 2️⃣-B 部署到 AWS — EKS 方案

适合已有 EKS 集群的团队。详见 [docs/legacy-eks/SETUP.md](./docs/legacy-eks/SETUP.md)。

```bash
cd terraform && terraform apply
helm install aws-load-balancer-controller ...
helm install aws-cn ./chart -f values-aws-cn.yaml -n mcp
```

### 3️⃣ 配置 AWS DevOps Agent（Agent Space 控制台）

**Step A: 创建 Private Connection**

Agent Space → Private Connections → Create

| 字段 | 填什么 |
|------|--------|
| Name | 随意（如 `ecs-mcp`） |
| VPC | 选 terraform 输出的 `vpc_id` |
| Subnets | 选 private subnets |
| Security Groups | 选 `mcp-alb` SG |
| Host address | 填 `terraform output alb_dns_name` 的值 |
| Certificate | 留空（ACM 公有证书不需要额外 PEM） |

等待状态变为 Completed（最多 10 分钟）。

**Step B: 注册 MCP Server**（每个账号一条）

Agent Space → Capabilities → MCP Servers → Add

| 字段 | 填什么 |
|------|--------|
| Name | 如 `aws-cn-mcp` |
| Endpoint URL | `https://<你的host>/mcp`（如 `https://aws-cn.example.com/mcp`） |
| Dynamic Client Registration | 不勾 |
| Private Connection | 选上面创建的 `ecs-mcp` |

**Step C: 验证**

在 Operator Web App 里发：`查 aws-cn 的 VPC`

关键原理：
- **Host address** 填 ALB DNS name — Private Connection 用它找到 ALB
- **Endpoint URL** 里的域名 — 作为 HTTP Host header，ALB 用它做路由分发到对应的 ECS Service
- **一条 Private Connection 复用所有 MCP Server** — 都走同一个 ALB，按域名区分

---

## DevOps Agent 对 MCP Server 的要求

| 要求 | 本方案如何满足 |
|---|---|
| Streamable HTTP transport | `AWS_API_MCP_TRANSPORT=streamable-http`（aws-api-mcp-server 原生支持）|
| HTTPS endpoint | 内部 ALB + ACM 公共通配符证书 `*.example.cloud` |
| 私网可达（无公网暴露）| Private Connection (VPC Lattice Resource Gateway) |
| 支持 HA（多副本）| `AWS_API_MCP_STATELESS_HTTP=true` + replicas=2 |
| 健康检查 | Ingress 加 `success-codes: "200,404,406"` 适配 MCP Server 对 GET 返 406 |

---

## 凭证传入方式

### 模式 A：AK/SK（默认）

环境变量注入 → boto3 读取：

```yaml
env:
  - { name: AWS_DEFAULT_REGION,    value: "cn-north-1" }
  - { name: AWS_ACCESS_KEY_ID,     valueFrom: { secretKeyRef: { name: mcp-creds, key: AWS_CN_AK } } }
  - { name: AWS_SECRET_ACCESS_KEY, valueFrom: { secretKeyRef: { name: mcp-creds, key: AWS_CN_SK } } }
```

⚠️ **AWS 中国区是独立 partition**，全球区凭证在中国区会 AuthFailure。需要在 [amazonaws.cn](https://amazonaws.cn) 开账号单独拿 AK/SK。

### 模式 B：IAM Roles Anywhere（企业级推荐）

X.509 证书 → Roles Anywhere 临时凭证 → Hub AssumeRole → Spoke 临时凭证：

```
容器启动 → 写证书到文件 → 注册 credential_process（AWS_CONFIG_FILE）
SDK 按需调用 credential-helper.sh：
  aws_signing_helper → Hub 临时凭证 → sts:AssumeRole → Spoke 临时凭证
botocore 读 Expiration，临近过期自动重新调用 helper（惰性刷新，无后台线程）
```

- 无长期密钥，证书泄露可 CRL 秒级吊销
- 一张证书管所有账号（Hub-Spoke 扇出）
- 详细配置步骤：**[docs/deploy/DEPLOY-ROLES-ANYWHERE.md](./docs/deploy/DEPLOY-ROLES-ANYWHERE.md)**

---

## 已知限制

| 问题 | 当前状态 | 改进方向 |
|---|---|---|
| **API Key 鉴权未强制** | ALB 不校验 header，靠 Private Connection 网络隔离兜底 | 加 ALB Lambda authorizer 或启用 OAuth（`AUTH_TYPE=oauth`）|
| **单 NAT Gateway** | 单 AZ，是 SPOF | 生产环境每 AZ 一个 NAT |
| **阿里云 MCP 不支持 stateless** | 强制 replicas=1 | 等上游 `alibaba-cloud-ops-mcp-server` 支持 |
| **证书自动续签** | ACM 公共证书自动续，DNS 验证 CNAME 需保留 | 不要删 DNSPod 里的 `_0dcdf890...` CNAME |

---

## 升级 MCP Server 版本

pin 在 `deploy/Dockerfile`：

```dockerfile
RUN pip install --no-cache-dir awslabs.aws-api-mcp-server==1.3.33
```

升级：改版本号 → `docker build` → 推 ECR → 重启服务：

```bash
# ECS 方案
aws ecs update-service --cluster mcp --service mcp-aws-cn --force-new-deployment

# EKS 方案
kubectl -n mcp rollout restart deploy/mcp-aws-cn
```

---

## 进一步阅读

- **[docs/deploy/DEPLOY-ROLES-ANYWHERE.md](./docs/deploy/DEPLOY-ROLES-ANYWHERE.md)** —— 🔐 IAM Roles Anywhere 零密钥认证部署指南
- **[docs/deploy/DEPLOY-RA-RECORD.md](./docs/deploy/DEPLOY-RA-RECORD.md)** —— 真实部署日志（含精确命令，可复制执行）
- **[docs/deploy/REBUILD.md](./docs/deploy/REBUILD.md)** —— 销毁现有资源 + 按最新代码重建的 runbook
- **[docs/legacy-eks/SETUP.md](./docs/legacy-eks/SETUP.md)** —— ⚠️ 旧版 EKS 方案从零到运行的完整步骤
- **[docs/legacy-eks/MULTI-ACCOUNT.md](./docs/legacy-eks/MULTI-ACCOUNT.md)** —— ⚠️ 旧版 EKS 多账号扩展运维
- **[docs/blog/BLOG.md](./docs/blog/BLOG.md)** —— 7 个大坑的故事版排查
- **[MCP 协议规范](https://modelcontextprotocol.io)**
