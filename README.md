# aws-devops-agent-external-mcp

把 **AWS DevOps Agent** 连接到自建 MCP Server，通过 VPC Lattice Private Connection 在私网完成端到端调用。支持 **ECS Fargate**（推荐）和 **EKS** 两种部署方式。

**零业务代码** —— 所有 MCP Server 用官方包（`awslabs.aws-api-mcp-server`、`alibaba-cloud-ops-mcp-server` 等），本项目只做容器化、编排、AWS 网络接线。

> 🚀 **ECS Fargate 方案（推荐）**：一个 `terraform apply` 搞定全部，无需 K8s → [blog/04-ecs-fargate-lightweight.md](./blog/04-ecs-fargate-lightweight.md)
> 📖 **EKS 方案完整部署步骤**：[SETUP.md](./SETUP.md)
> 🐛 **踩坑故事版博客（7 个层面的故障定位）**：[BLOG.md](./BLOG.md)
> 🏗️ **多账号扩展运维指南**（Helm chart + ESO）：[MULTI-ACCOUNT.md](./MULTI-ACCOUNT.md)
> 🔥 **从零重建 runbook**（destroy 现有 + 按最新代码 Mode B 重部）：[REBUILD.md](./REBUILD.md)

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
                                            ACM *.yingchu.cloud        └──→│ aliyun-prod (Fargate)   │
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
| **DNS split-horizon** | `yingchu.cloud` 公网在 Tencent DNSPod，私网在 Route53 私有 zone，各管各的 |

---

## 两种部署方案

| | **ECS Fargate（推荐）** | **EKS** |
|---|---|---|
| 部署命令 | `terraform apply`（一步） | terraform + helm×3 + kubectl（五步） |
| 月固定成本 | ~$57（NAT $32 + ALB $16 + Fargate ~$9/service） | ~$130（NAT + ALB + EKS 控制面 $72 + Node） |
| 加账号 | 改 tfvars + `terraform apply` | 写 values.yaml + `helm install` |
| 凭证管理 | Secrets Manager 直读（原生） | ESO + IRSA + ClusterSecretStore |
| 适合 | 大多数场景、没有 K8s 的团队 | 已有 EKS、需要跑十几个微服务的场景 |
| 目录 | `terraform-ecs/` | `terraform/` + `chart/` + `chart-aliyun/` |
| 博客 | [04-ecs-fargate-lightweight.md](./blog/04-ecs-fargate-lightweight.md) | [01](./blog/01-single-account-bridge.md) / [02](./blog/02-multi-account-extension.md) / [03](./blog/03-skills-in-action.md) |

---

## 目录

```
.
├── README.md                    ← 你在这
├── SETUP.md                     ← EKS 方案完整配置指南
├── BLOG.md                      ← 故事版踩坑博客
├── MULTI-ACCOUNT.md             ← EKS 多账号扩展运维
├── blog/                        ← 系列博客（01-04）
├── docker-compose.yml           ← 本地冒烟测试
├── deploy/
│   ├── Dockerfile               ← AWS MCP 镜像
│   └── Dockerfile.aliyun        ← 阿里云 MCP 镜像
├── terraform-ecs/               ← ⭐ ECS Fargate 方案（推荐）
│   ├── main.tf                  ← Provider
│   ├── variables.tf             ← accounts map（多账号 + 跨云）
│   ├── network.tf               ← IGW + NAT Gateway + 路由表
│   ├── alb.tf                   ← Internal ALB + HTTPS listener
│   ├── ecs.tf                   ← ECS Cluster + for_each Services
│   ├── iam.tf                   ← Execution Role + Task Role
│   ├── outputs.tf               ← ALB DNS name + DNS 操作提示
│   └── terraform.tfvars.example ← 配置模板
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

详见 [blog/04-ecs-fargate-lightweight.md](./blog/04-ecs-fargate-lightweight.md)。

### 2️⃣-B 部署到 AWS — EKS 方案

适合已有 EKS 集群的团队。详见 [SETUP.md](./SETUP.md)。

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
| HTTPS endpoint | 内部 ALB + ACM 公共通配符证书 `*.yingchu.cloud` |
| 私网可达（无公网暴露）| Private Connection (VPC Lattice Resource Gateway) |
| 支持 HA（多副本）| `AWS_API_MCP_STATELESS_HTTP=true` + replicas=2 |
| 健康检查 | Ingress 加 `success-codes: "200,404,406"` 适配 MCP Server 对 GET 返 406 |

---

## 凭证传入方式

**AWS 全球区 / 中国区**：环境变量注入 → boto3 读取

```yaml
env:
  - { name: AWS_DEFAULT_REGION,    value: "cn-north-1" }           # 切区靠这个
  - { name: AWS_ACCESS_KEY_ID,     valueFrom: { secretKeyRef: { name: mcp-creds, key: AWS_CN_AK } } }
  - { name: AWS_SECRET_ACCESS_KEY, valueFrom: { secretKeyRef: { name: mcp-creds, key: AWS_CN_SK } } }
```

⚠️ **AWS 中国区是独立 partition**，全球区凭证在中国区会 AuthFailure。需要在 [amazonaws.cn](https://amazonaws.cn) 开账号单独拿 AK/SK。

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

- **[blog/04 - ECS Fargate 轻量化方案](./blog/04-ecs-fargate-lightweight.md)** —— 推荐的部署方式，含完整配置指南
- **[blog/01 - 单账号桥接](./blog/01-single-account-bridge.md)** —— 为什么要建桥 + EKS 单账号
- **[blog/02 - 多账号扩展](./blog/02-multi-account-extension.md)** —— EKS 多账号 + 跨云 + 凭证轮换
- **[blog/03 - Skills 实战](./blog/03-skills-in-action.md)** —— 8 个 Skill 让 Agent 理解多账号场景
- **[SETUP.md](./SETUP.md)** —— EKS 方案从零到运行的完整步骤
- **[BLOG.md](./BLOG.md)** —— 7 个大坑的故事版排查
- **[MCP 协议规范](https://modelcontextprotocol.io)**
