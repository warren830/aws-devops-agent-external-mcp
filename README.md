# aws-devops-agent-external-mcp

把 **AWS DevOps Agent** 连接到部署在 EKS 上的自建 MCP Server，通过 VPC Lattice Private Connection 在私网完成端到端调用。

**零业务代码** —— 所有 MCP Server 用官方包（`awslabs.aws-api-mcp-server` 等），本项目只做容器化、K8s 编排、AWS 网络接线。

> 📖 **完整部署步骤（含踩坑避雷）**：[SETUP.md](./SETUP.md)
> 🐛 **踩坑故事版博客（7 个层面的故障定位）**：[BLOG.md](./BLOG.md)
> 🏗️ **多账号扩展运维指南**（Helm chart + ESO）：[MULTI-ACCOUNT.md](./MULTI-ACCOUNT.md)
> 🔥 **从零重建 runbook**（destroy 现有 + 按最新代码 Mode B 重部）：[REBUILD.md](./REBUILD.md)

---

## 架构

```
┌──────────────────┐      ┌─────────────────┐      ┌───────────────┐       ┌──────────────────────┐
│ AWS DevOps Agent │──────│ Private         │──────│ Internal ALB  │───┬──→│ aws-global Pod (AK1) │
│ (Agent Space)    │ VPC  │ Connection      │ 内网 │ (HTTPS:443)   │   │   └──────────────────────┘
└──────────────────┘ Lat. │ (Resource GW)   │      │ host-based    │   │   ┌──────────────────────┐
                          └─────────────────┘      │ routing       │   └──→│ aws-cn Pod (AK2)     │
                                                   └───────────────┘       └──────────────────────┘
                                                          ↑
                                            ACM 公共通配符 *.yingchu.cloud 证书
                                            aws-global.yingchu.cloud / aws-cn.yingchu.cloud
                                            (Route53 私有 Zone，仅 VPC 内解析)
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

## 目录

```
.
├── README.md                    ← 你在这
├── SETUP.md                     ← 完整配置指南（含所有坑的排查表）
├── BLOG.md                      ← 故事版，按遇到问题的时间顺序讲 7 个大坑
├── MULTI-ACCOUNT.md             ← 多账号扩展运维（加新账号的 5 步 checklist + ESO 启用）
├── docker-compose.yml           ← 本地 4 服务冒烟测试（aws-global/aws-cn/aliyun/gcp）
├── .env.example                 ← 凭证模板
├── chart/                       ← ⭐ AWS MCP chart（每账号一个 release）
│   ├── Chart.yaml
│   ├── values.yaml              ← 全局默认
│   ├── values-aws-global.yaml   ← 账号级覆盖
│   ├── values-aws-cn.yaml
│   ├── templates/               ← Deployment / Service / Ingress / ExternalSecret
│   └── README.md                ← chart 用法速查
├── chart-aliyun/                ← ⭐ 阿里云 MCP chart（独立因为 fastmcp 依赖冲突）
│   ├── Chart.yaml
│   ├── values.yaml
│   ├── values-aliyun-prod.yaml
│   ├── templates/
│   └── README.md
├── deploy/
│   ├── Dockerfile               ← AWS 镜像（aws-api-mcp-server）
│   ├── Dockerfile.aliyun        ← 阿里云镜像（alibaba-cloud-ops-mcp-server）
│   ├── cluster-secret-store.yaml ← ESO 配置（Phase 2 用）
│   ├── k8s-2svc.yaml            ← 当前运行版（aws-global + aws-cn 硬编码）
│   ├── k8s.yaml                 ← 参考：完整 4 服务版（含 aliyun/gcp，未 apply）
│   └── README.md                ← deploy 目录的补充说明
├── terraform/
│   └── main.tf                  ← VPC + EKS + LB Controller IRSA
└── scripts/
    └── smoke.sh                 ← 本地 docker-compose 冒烟测试
```

---

## 快速开始

### 1️⃣ 本地验证（不需要 AWS 资源）

```bash
cp .env.example .env
vim .env                        # 填 AWS/aliyun/GCP 凭证

docker compose up -d
bash scripts/smoke.sh           # 对本地 4 个端口发 MCP initialize 握手
```

端口映射：`8001` aws-global / `8002` aws-cn / `8003` aliyun / `8004` gcp。

### 2️⃣ 部署到 AWS EKS

**想一步步跟做，直接看 [SETUP.md](./SETUP.md)。** 以下是概览：

```bash
# a. 基础设施
cd terraform && terraform apply -auto-approve
$(terraform output -raw kubeconfig_cmd)

# b. ALB Controller
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system --set clusterName=<cluster_name> --wait

# c. 镜像
aws ecr create-repository --repository-name aws-devops-agent-external-mcp --region us-east-1
docker build --platform linux/amd64 -t <ECR>:latest -f deploy/Dockerfile .
docker push <ECR>:latest

# d. 证书（必须用公共 ACM 证书，不要自签！血泪教训见 BLOG.md 坑 #5）
# e. Route53 私有 zone + CNAME 到 ALB
# f. 凭证 Secret
# g. kubectl apply -f deploy/k8s-2svc.yaml
```

### 3️⃣ 配置 AWS DevOps Agent

这步最多坑，[SETUP.md 第 6 节](./SETUP.md#6-part-4--配置-aws-devops-agent坑最多的一步) 有详细表格。核心要点：

- **Private Connection 的 Host address** 填 **ALB 的 AWS 托管 DNS 名**（`internal-k8s-mcp-*.us-east-1.elb.amazonaws.com`），不是 `.yingchu.cloud` —— 字段要求公网可解析
- **Endpoint URL** 填 `https://aws-cn.yingchu.cloud/mcp` —— 只用作 Host header + TLS SNI，不做 DNS 解析
- **一条 Private Connection 可以服务多个 MCP Server**（只要都在同一个 ALB 后面）
- **Register 完毕后，必须再去 Agent Space 的 Capabilities → MCP Servers 里 Add** —— Register 只是账户级上架，不 Add 到具体 Agent 它不知道有这回事

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
| **API Key 鉴权未强制** | ALB 不校验 header，靠 Private Connection 网络隔离兜底 | 加 ALB Lambda authorizer 或启用 aws-api-mcp-server 的 OAuth（`AUTH_TYPE=oauth`）|
| **仅部署 2 个 MCP（aws-global/aws-cn）** | aliyun/gcp 在 `k8s.yaml` 里有参考定义，未 apply | 需要时拆独立镜像（pip 依赖冲突，别跟 AWS 的混装）|
| **证书 13 个月过期** | ACM 公共证书自动续签，但 Route53 私有 zone 关联 VPC 得保持 | 定期 renewal check |
| **EKS 节点在公有子网** | 简化版部署 | 生产换成私有 subnet + NAT Gateway（git 上有 commit，未 apply）|

---

## 升级 MCP Server 版本

pin 在 `deploy/Dockerfile`：

```dockerfile
ARG AWS_MCP_VERSION=1.3.33
```

升级：改版本号 → `docker build` → `smoke.sh` 验证 → 推 ECR → `kubectl -n mcp rollout restart deploy/aws-global deploy/aws-cn`。

---

## 进一步阅读

- **[SETUP.md](./SETUP.md)** —— 从零到运行的完整步骤，含 8 个故障排查场景
- **[BLOG.md](./BLOG.md)** —— 按实际遇到顺序讲的 7 个大坑（supergateway crash、Docker Hub DNS 污染、ALB 健康检查、自签证书、Private Connection Host address 误解、stateful session、Register vs Add）
- **[AWS 官方 Blog: Securely connect AWS DevOps Agent to private services in your VPCs](https://aws.amazon.com/blogs/devops/securely-connect-aws-devops-agent-to-private-services-in-your-vpcs/)** —— 早读能省 3 个坑
- **[MCP 协议规范](https://modelcontextprotocol.io)**
- **[FastMCP 框架](https://gofastmcp.com)** —— aws-api-mcp-server 的底层 Python MCP Server 框架
