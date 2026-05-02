# aws-devops-agent-external-mcp

用 **AWS DevOps Agent** 统一管理 AWS 全球区、AWS 中国区、阿里云、GCP (Cloud Run)。

**零业务代码** — 全部使用各云厂商官方 MCP Server，只做部署和接线。

## 架构

```
AWS DevOps Agent (us-east-1)
    │
    │  Private Connection (VPC Lattice)
    ▼
内部 ALB (HTTPS:443, 按 Host header 分流)
    │
    ├─ aws-global.mcp.internal/mcp  →  awslabs.aws-api-mcp-server        (AK/SK=全球区)
    ├─ aws-cn.mcp.internal/mcp      →  awslabs.aws-api-mcp-server        (AK/SK=中国区, region=cn-north-1)
    ├─ aliyun.mcp.internal/mcp      →  alibaba-cloud-ops-mcp-server
    └─ gcp.mcp.internal/mcp         →  @google-cloud/cloud-run-mcp       (scope: Cloud Run only, 见下方说明)
```

关键点：
- AWS 全球区和中国区用**同一个** MCP Server 包，只是 AK/SK 和 region 不同
- 所有 MCP Server 都 **原生支持 Streamable HTTP**，无需 `supergateway` 之类的协议翻译层
- 一个内部 ALB 按 **Host header** 分流到不同容器（不用 path 路由是因为三方 MCP Server 都把 endpoint 硬编码在 `/mcp`）
- 证书用通配符 `*.mcp.internal`，一次签发覆盖所有子域名

### GCP 覆盖范围说明（重要）

GCP 这侧的工具范围**远小于** AWS 和阿里云：

- **目前只覆盖**：Cloud Run 部署、Cloud Build、Artifact Registry、Secret Manager、Cloud Storage、Logging、Billing
- **不覆盖**：GCE 实例、GKE、BigQuery、Pub/Sub、IAM、Networking 等

原因：Google 官方目前只发布了 `@google-cloud/cloud-run-mcp` 一个 MCP Server，还没有类似 `aws-api-mcp-server` 那种覆盖全 `gcloud` CLI 的通用包。本项目坚持"零业务代码"原则，不自建 wrapper。等 Google 官方补齐后，换掉 image 即可无缝升级。

## 目录

```
.
├── README.md
├── docker-compose.yml          # 本地验证（4 个服务：aws-global/aws-cn/aliyun/gcp）
├── .env.example                # 四套凭证模板
├── deploy/
│   ├── Dockerfile              # python:3.12-slim + pip 预装两个 Python MCP Server（版本 pin）
│   ├── k8s.yaml                # 4 个 Deployment + 4 个 Service + host-based Ingress
│   └── README.md               # 部署补充说明
├── terraform/
│   └── main.tf                 # VPC + EKS + LB Controller IRSA
└── scripts/
    └── smoke.sh                # 本地冒烟测试（MCP initialize 握手）
```

## 工作原理

### 为什么不需要 supergateway

所有使用的 MCP Server 都已经原生支持 Streamable HTTP：

| MCP Server | 启用方式 | 默认 path |
|---|---|---|
| `awslabs.aws-api-mcp-server` | 环境变量 `AWS_API_MCP_TRANSPORT=streamable-http` | `/mcp` |
| `alibaba-cloud-ops-mcp-server` | CLI 参数 `--transport streamable-http` | `/mcp` |
| `@google-cloud/cloud-run-mcp` | 默认即是（容器化运行时） | `/mcp` |

过去需要 `supergateway` 把 stdio 翻译成 Streamable HTTP，现在 MCP Server 直接裸出 HTTP，**少一层中间件 = 更少故障面、更小镜像、更快启动**。

### 凭证是怎么传进去的

**AWS 全球区 / 中国区：** 环境变量注入 → boto3 读取

```yaml
env:
  - name: AWS_DEFAULT_REGION
    value: "cn-north-1"           # boto3 看这个决定调哪个区
  - name: AWS_ACCESS_KEY_ID
    valueFrom:
      secretKeyRef:
        name: mcp-creds
        key: AWS_CN_AK
```

**阿里云：** 环境变量注入 → alibaba-cloud SDK 读取

```yaml
env:
  - { name: ALIBABA_CLOUD_ACCESS_KEY_ID,     valueFrom: { secretKeyRef: ... } }
  - { name: ALIBABA_CLOUD_ACCESS_KEY_SECRET, valueFrom: { secretKeyRef: ... } }
```

**GCP：** Service Account JSON 通过 Secret 挂载到 Pod，用 Application Default Credentials 机制

```yaml
env:
  - name: GOOGLE_APPLICATION_CREDENTIALS
    value: "/var/secrets/gcp/key.json"
volumeMounts:
  - { name: gcp-sa, mountPath: /var/secrets/gcp, readOnly: true }
volumes:
  - name: gcp-sa
    secret:
      secretName: gcp-sa-key
```

## 快速开始

### 1. 本地验证（不需要 EKS）

```bash
cp .env.example .env
# 填入四套凭证（GCP 侧需要额外把 service-account JSON 放到 ./gcp-sa-key.json）
vim .env

docker compose up -d

bash scripts/smoke.sh        # 对 4 个端口发 MCP initialize 握手
```

端口映射：
- `8001` → aws-global
- `8002` → aws-cn
- `8003` → aliyun
- `8004` → gcp

### 2. 部署到 AWS EKS

#### 2a. 创建基础设施

**网络拓扑（Level 2：私有 subnet + NAT Gateway）**

```
VPC 10.42.0.0/16
├─ public  10.42.0.0/20, 10.42.16.0/20
│    └─ NAT Gateway（单个，跨 AZ 共享 —— 省 $32/月但是 SPOF）
└─ private 10.42.128.0/20, 10.42.144.0/20
     ├─ EKS worker nodes（无公网 IP）
     ├─ internal ALB（host-based 路由 4 个子域名）
     └─ DevOps Agent Private Connection 注入 ENI 的目标 subnet
```

```bash
cd terraform
terraform init && terraform plan     # 先看要动什么，确认后再 apply
terraform apply -auto-approve
# 输出: cluster_name, vpc_id, public_subnets, private_subnets, lb_controller_role_arn

$(terraform output -raw kubeconfig_cmd)
```

成本粗估（us-east-1，单 NAT）：EKS $73/月 + t3.medium $30 + NAT $32 + ALB $16 ≈ **$150/月**（不含流量处理费）。升 per-AZ NAT 再 +$32。

#### 2b. 安装 AWS Load Balancer Controller

```bash
helm repo add eks https://aws.github.io/eks-charts
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=$(terraform output -raw cluster_name) \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=$(terraform output -raw lb_controller_role_arn) \
  --set region=us-east-1 \
  --set vpcId=$(terraform output -raw vpc_id) \
  --wait
```

#### 2c. 创建 HTTPS 证书和域名

**用通配符证书覆盖所有子域名**（因为是 host-based 路由）：

```bash
# 创建 Route53 私有托管区
aws route53 create-hosted-zone \
  --name mcp.internal \
  --caller-reference "mcp-$(date +%s)" \
  --vpc VPCRegion=us-east-1,VPCId=$(terraform output -raw vpc_id) \
  --hosted-zone-config PrivateZone=true

# 生成带 SAN 的自签通配符证书
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /tmp/mcp-key.pem -out /tmp/mcp-cert.pem \
  -subj "/CN=*.mcp.internal" \
  -addext "subjectAltName=DNS:*.mcp.internal,DNS:mcp.internal"

# 导入 ACM
aws acm import-certificate --region us-east-1 \
  --certificate fileb:///tmp/mcp-cert.pem \
  --private-key fileb:///tmp/mcp-key.pem
# 记下输出的 CertificateArn，替换 k8s.yaml 中的 <CERTIFICATE_ARN>
```

#### 2d. 部署 MCP 容器

```bash
# 构建推镜像（AWS + 阿里云共用；GCP 用官方 image，不需要自建）
ECR=<account-id>.dkr.ecr.us-east-1.amazonaws.com/aws-devops-agent-external-mcp
aws ecr create-repository --repository-name aws-devops-agent-external-mcp --region us-east-1
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin $ECR
docker build --platform linux/amd64 -t $ECR:latest -f deploy/Dockerfile .
docker push $ECR:latest

# 替换 k8s.yaml 中的镜像地址和证书 ARN
sed -i '' "s|<ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/aws-devops-agent-external-mcp|$ECR|g" deploy/k8s.yaml
sed -i '' "s|<CERTIFICATE_ARN>|<your-cert-arn>|" deploy/k8s.yaml

# 创建凭证 Secret
kubectl create namespace mcp
kubectl -n mcp create secret generic mcp-creds \
  --from-literal=AWS_GLOBAL_AK=<全球区 AK> \
  --from-literal=AWS_GLOBAL_SK=<全球区 SK> \
  --from-literal=AWS_CN_AK=<中国区 AK> \
  --from-literal=AWS_CN_SK=<中国区 SK> \
  --from-literal=ALIYUN_AK=<阿里云 AK> \
  --from-literal=ALIYUN_SK=<阿里云 SK> \
  --from-literal=GCP_PROJECT_ID=<your-gcp-project-id>

# GCP 额外创建 service-account key Secret
kubectl -n mcp create secret generic gcp-sa-key --from-file=key.json=./gcp-sa-key.json

# 部署
kubectl apply -f deploy/k8s.yaml
```

#### 2e. 添加 DNS 记录

所有 4 个子域名都指向同一个 ALB：

```bash
ALB_DNS=$(kubectl -n mcp get ingress mcp -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
ZONE_ID=<your-private-zone-id>

for host in aws-global aws-cn aliyun gcp; do
  aws route53 change-resource-record-sets --hosted-zone-id $ZONE_ID --change-batch "{
    \"Changes\": [{
      \"Action\": \"UPSERT\",
      \"ResourceRecordSet\": {
        \"Name\": \"${host}.mcp.internal\",
        \"Type\": \"CNAME\",
        \"TTL\": 60,
        \"ResourceRecords\": [{\"Value\": \"$ALB_DNS\"}]
      }
    }]
  }"
done
```

### 3. 配置 AWS DevOps Agent

#### 3a. 创建 Private Connection

控制台 → **DevOps Agent** → **Capability Providers** → **Private connections** → **Create**

| 字段 | 值 |
|---|---|
| Host address | ALB 内部 DNS（`internal-k8s-mcp-*.us-east-1.elb.amazonaws.com`） |
| VPC | EKS 所在 VPC |
| Subnets | **选 private subnets**（`terraform output -raw private_subnets`），各 AZ 各一个 |
| TCP port | 443 |

等状态变 `Completed`（约 10 分钟）。**一条 Private Connection 供所有 4 个 MCP Server 共用。**

> 为什么用 private subnets：DevOps Agent 会在这些 subnet 里注入 ENI，端到端流量路径 DevOps Agent → 注入 ENI → internal ALB → node → pod 全部在私网内完成，不经过公网。

#### 3b. 注册 4 个 MCP Server

控制台 → **Capability Providers** → **MCP Server** → **Register**（重复 4 次）：

| Name | Endpoint URL |
|---|---|
| `aws-global` | `https://aws-global.mcp.internal/mcp` |
| `aws-cn`     | `https://aws-cn.mcp.internal/mcp`     |
| `aliyun`     | `https://aliyun.mcp.internal/mcp`     |
| `gcp`        | `https://gcp.mcp.internal/mcp`        |

#### 3c. 在 Agent Space 关联 MCP

Agent Space → **Capabilities** → **MCP Servers** → **Add** → 选择刚注册的 4 个 MCP → Allow all tools → **Add**

### 4. 验证

在 Agent Space 聊天中测试：

```
List all EC2 instances in us-east-1           → 走 aws-global
List all EC2 instances in cn-northwest-1      → 走 aws-cn
List my ECS instances in aliyun cn-hangzhou   → 走 aliyun
List my Cloud Run services                    → 走 gcp
```

## DevOps Agent 对 MCP Server 的要求

| 要求 | 本方案如何满足 |
|---|---|
| Streamable HTTP transport | 所有 MCP Server 原生支持，无需中间件 |
| HTTPS endpoint | 内部 ALB + ACM 通配符证书 |
| 私网可达 | Private Connection (VPC Lattice) |

## 已知限制与后续工作

| 问题 | 当前状态 | 建议 |
|---|---|---|
| **API Key 鉴权尚未落地** | ALB 不强制 header 校验，Private Connection 是唯一防线 | 加 ALB Lambda authorizer 或启用 AWS MCP Server 自带的 OAuth（`AUTH_TYPE=oauth` + `AUTH_ISSUER` + `AUTH_JWKS_URI`） |
| **GCP 覆盖范围窄** | 只有 Cloud Run 相关 | 等 Google 发布通用 gcloud MCP；或评估社区 `google-cloud-mcp` |
| **自签证书 365 天过期** | 无续期自动化 | 生产换成 ACM Private CA 或内部 CA 签发 |
| ~~**Node 在公有子网、无 NAT**~~ | ✅ 已改：节点在私有 subnet + 单 NAT Gateway | 如需 HA 把 `single_nat_gateway` 设为 `false` |

## 升级 MCP Server 版本

Pin 的版本号在 `deploy/Dockerfile` 里：

```dockerfile
ARG AWS_MCP_VERSION=1.3.33
ARG ALIYUN_MCP_VERSION=0.9.27
```

升级流程：改这两个值 → 本地 `docker build` → `bash scripts/smoke.sh` 验证 → 推 ECR → `kubectl rollout restart`。

GCP 那个拉 `us-docker.pkg.dev/cloudrun/container/mcp:latest`，版本节奏跟随 Google 官方 —— 生产建议 pin 到具体 digest：

```yaml
image: us-docker.pkg.dev/cloudrun/container/mcp@sha256:<digest>
```
