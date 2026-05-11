# AWS DevOps Agent × 私网 MCP Server 完整配置指南

> 实战记录 —— 从零把 AWS DevOps Agent 接到部署在 EKS 上的自建 MCP Server，覆盖架构、部署、排错。
>
> 本文档是**工程参考**，侧重"每一步做什么、填什么值、报错怎么处理"。想看故事版请读 [BLOG.md](./BLOG.md)。

---

## 1. 架构与目标

### 整条链路

```
┌──────────────────┐       ┌─────────────────┐       ┌────────────────┐       ┌───────┐
│ AWS DevOps Agent │──────→│ Private         │──────→│ Internal ALB   │──────→│  Pod  │
│ (Agent Space)    │ VPC   │ Connection      │ VPC   │ (HTTPS:443)    │       │ MCP   │
└──────────────────┘ Lat.  │ (Resource GW)   │ 内网  │ host-based     │       │ Server│
                           └─────────────────┘       │ routing        │       └───────┘
                                                     └────────────────┘
                                                            │
                                                            ├─ aws-global.yingchu.cloud ─→ aws-global Service
                                                            └─ aws-cn.yingchu.cloud     ─→ aws-cn Service
```

**为什么这么设计**
- Agent 在 AWS 托管，MCP Server 在客户 VPC —— **Private Connection**（底层 VPC Lattice Resource Gateway）是唯一合规的私网互通方案，不用 VPN / TGW / 公网暴露
- 一个 ALB 用 **host-based routing** 服务多个 MCP Server —— 一条 Private Connection 能复用，一张证书能覆盖
- MCP Server 用**原生 Streamable HTTP**，不要 supergateway 这类中间件（少一层故障面，后面有踩坑说明）

### 组件清单（实际部署的值）

| 资源 | 标识 |
|---|---|
| AWS Account | `034362076319` |
| Region | `us-east-1` |
| EKS Cluster | `mcp-test` |
| VPC | `vpc-033d9e9955afde81f` |
| Public Subnets | `subnet-0ef7eec49e08c070c` (us-east-1a), `subnet-0ae59bc0fd7d71af4` (us-east-1b) |
| ALB DNS（公网可查，返回私有 IP） | `internal-k8s-mcp-mcp-6334395754-126597647.us-east-1.elb.amazonaws.com` |
| ALB SG | `sg-06a4ed260d90bd259` (k8s-mcp-mcp-79298410f1) |
| ACM 公共通配符证书 | `arn:aws:acm:us-east-1:034362076319:certificate/74d2cea3-a33c-4841-920b-1d878a629c3a` |
| Route53 私有 Zone | `Z09231282I798DJM5YYUW` (`yingchu.cloud`) |
| ECR 仓库 | `034362076319.dkr.ecr.us-east-1.amazonaws.com/aws-devops-agent-external-mcp` |
| MCP Endpoints | `https://aws-cn.yingchu.cloud/mcp`, `https://aws-global.yingchu.cloud/mcp` |

---

## 2. Prerequisites

### 工具

| 工具 | 用途 | 检查 |
|---|---|---|
| `aws` CLI | 管理 AWS 资源 | `aws --version` 建议 ≥ 2.36 才支持 `devops-agent` 子命令 |
| `kubectl` | 操作 EKS | `kubectl version --client` |
| `terraform` | 部署 VPC + EKS | `terraform version` ≥ 1.5 |
| `docker` | 构建镜像（需登录 amazonians 组织）| Docker Desktop 需登录企业账号 |
| `helm` | 装 AWS Load Balancer Controller | `helm version` |
| `openssl` | 生成自签证书（如果不用公共 CA） | 系统自带 |

### AWS 账户

- 可创建 EKS / VPC / Route53 / ACM / ECR / VPC Lattice 的权限
- **AWS DevOps Agent 可用**（目前 `us-east-1` 可用，Preview 阶段可能需要额外申请）
- （可选）一个公网 DNS 域名 + ACM 公共签发的通配符证书 —— 强烈推荐，能绕开一堆自签证书信任问题

---

## 3. Part 1 — 部署 EKS + ALB Controller

### 3.1 Terraform apply

```bash
cd terraform
terraform init
terraform plan          # 确认要创建哪些资源
terraform apply -auto-approve
# 输出：cluster_name, vpc_id, public_subnets, lb_controller_role_arn
$(terraform output -raw kubeconfig_cmd)   # 更新 kubeconfig
```

`terraform/main.tf` 里现在是**公有 subnet + EKS node** 的简单拓扑。生产环境建议私有 subnet + NAT Gateway（仓库里有 git commit 版本的带 NAT 配置，但没 apply —— 根据你的安全等级选）。

### 3.2 装 AWS Load Balancer Controller

```bash
helm repo add eks https://aws.github.io/eks-charts
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=$(terraform -chdir=terraform output -raw cluster_name) \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=$(terraform -chdir=terraform output -raw lb_controller_role_arn) \
  --set region=us-east-1 \
  --set vpcId=$(terraform -chdir=terraform output -raw vpc_id) \
  --wait
```

---

## 4. Part 2 — DNS + 证书

### 4.1 证书：用公共 ACM 证书（强烈推荐）

前提：你在 Route53 或其他权威 DNS 管理过一个公网域名（比如 `yingchu.cloud`），并已签发 ACM 公共通配符证书。

```bash
# 确认证书 ARN、SANs、状态
aws acm describe-certificate --region us-east-1 \
  --certificate-arn <YOUR_CERT_ARN> \
  --query 'Certificate.{Issuer:Issuer,Status:Status,SANs:SubjectAlternativeNames,NotAfter:NotAfter}'
```

**为什么不用自签证书**：VPC Lattice 做 TLS 握手时会校验信任链。自签证书要手动把 PEM 贴到 Private Connection 的 "Certificate public key" 字段 —— 能做但容易出错，而且每次 rotate 都得更新。公共证书完全省这步。

### 4.2 Route53 私有 Hosted Zone

做 split-horizon DNS：公网 `yingchu.cloud` 继续由 Tencent DNSPod 等托管，私网由 Route53 专门为 VPC 服务。

```bash
# 创建私有 zone，关联到 EKS 所在 VPC
aws route53 create-hosted-zone \
  --name yingchu.cloud \
  --caller-reference "mcp-$(date +%s)" \
  --vpc VPCRegion=us-east-1,VPCId=vpc-033d9e9955afde81f \
  --hosted-zone-config PrivateZone=true,Comment="MCP private zone"
# 记下返回的 HostedZoneId
```

### 4.3 CNAME 指向 ALB

```bash
ALB=internal-k8s-mcp-mcp-6334395754-126597647.us-east-1.elb.amazonaws.com
ZONE_ID=Z09231282I798DJM5YYUW    # 上一步的输出

for host in aws-global aws-cn; do
  aws route53 change-resource-record-sets --hosted-zone-id $ZONE_ID --change-batch "{
    \"Changes\": [{
      \"Action\": \"UPSERT\",
      \"ResourceRecordSet\": {
        \"Name\": \"${host}.yingchu.cloud\",
        \"Type\": \"CNAME\",
        \"TTL\": 60,
        \"ResourceRecords\": [{\"Value\": \"$ALB\"}]
      }
    }]
  }"
done
```

> **注意**：Ingress 创建后 ALB 才存在，所以如果是首次部署，顺序是先 `kubectl apply` 出 ALB，拿到 DNS 再回来执行这一步。

---

## 5. Part 3 — 构建镜像 + 部署 MCP Servers

### 5.1 Dockerfile（关键）

```dockerfile
# 重要：用 public.ecr.aws 而不是 python:3.12-slim（Docker Hub 从国内常被 DNS 污染）
FROM public.ecr.aws/docker/library/python:3.12-slim

ARG AWS_MCP_VERSION=1.3.33

# 只装 aws-api-mcp-server。别同时装 alibaba-cloud-ops-mcp-server：
# 两者的 fastmcp 版本冲突，pip 会 ResolutionImpossible
RUN pip install --no-cache-dir \
      "awslabs.aws-api-mcp-server==${AWS_MCP_VERSION}"

RUN useradd --create-home --shell /bin/bash app
USER app
WORKDIR /home/app

EXPOSE 8000
```

### 5.2 构建 + 推镜像

```bash
# 先登录 Docker Desktop（如果你被 amazonians 组织策略强制登录）
# 在 Docker Desktop 应用里点右上角登录

# 创建 ECR 仓库（一次性）
aws ecr create-repository --repository-name aws-devops-agent-external-mcp --region us-east-1

# 登录 ECR
ECR=034362076319.dkr.ecr.us-east-1.amazonaws.com/aws-devops-agent-external-mcp
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin 034362076319.dkr.ecr.us-east-1.amazonaws.com

# 构建 + 推送（注意 --platform linux/amd64 -- Mac M 系列必须，否则 EKS node 跑不起来）
docker build --platform linux/amd64 -t $ECR:latest -f deploy/Dockerfile .
docker push $ECR:latest
```

### 5.3 创建凭证 Secret

```bash
kubectl create namespace mcp
kubectl -n mcp create secret generic mcp-creds \
  --from-literal=AWS_GLOBAL_AK='<AKIA_your_global_access_key>' \
  --from-literal=AWS_GLOBAL_SK='<your_global_secret_key>' \
  --from-literal=AWS_CN_AK='<AKIA_your_china_access_key>' \
  --from-literal=AWS_CN_SK='<your_china_secret_key>'
```

⚠️ **AWS 中国区是独立 partition**，全球区的 AK/SK 在中国区不生效。中国区凭证要从 [amazonaws.cn](https://amazonaws.cn) 账户生成。如果你没有，aws-cn 可以先跳过。

### 5.4 Kubernetes manifests

本项目的最简可用版在 `deploy/k8s-2svc.yaml`（只含 aws-global + aws-cn，不含 aliyun/gcp）。关键配置点：

```yaml
# Deployment
replicas: 1                                # ⚠️ 不能是 2！MCP Streamable HTTP 有 stateful session
                                           #    多副本 + ALB round-robin → "Session not found"
env:
  - { name: AWS_API_MCP_TRANSPORT, value: "streamable-http" }   # 原生 HTTP，不要 supergateway
  - { name: AWS_API_MCP_HOST,      value: "0.0.0.0" }
  - { name: AWS_API_MCP_PORT,      value: "8000" }
  - { name: AUTH_TYPE,             value: "no-auth" }
  - { name: AWS_API_MCP_ALLOWED_HOSTS,   value: "aws-cn.yingchu.cloud" }    # 防 Host header 伪造
  - { name: AWS_API_MCP_ALLOWED_ORIGINS, value: "aws-cn.yingchu.cloud" }

readinessProbe:
  tcpSocket: { port: 8000 }    # MCP Server 没 /healthz 端点，用 TCP probe
```

```yaml
# Ingress
annotations:
  alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS":443}]'
  alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:us-east-1:034362076319:certificate/74d2cea3-a33c-4841-920b-1d878a629c3a

  # ⚠️ ALB 健康检查配置（坑点之一）
  alb.ingress.kubernetes.io/healthcheck-path: "/mcp"
  alb.ingress.kubernetes.io/success-codes: "200,404,406"   # MCP 对 GET 返 406（Not Acceptable）
                                                            # 没这行会被 ALB 判定不健康
spec:
  rules:
    - host: aws-global.yingchu.cloud    # host-based 路由
      http:
        paths:
          - path: /
            pathType: Prefix
            backend: { service: { name: aws-global, port: { number: 8000 } } }
    - host: aws-cn.yingchu.cloud
      http:
        paths:
          - path: /
            pathType: Prefix
            backend: { service: { name: aws-cn, port: { number: 8000 } } }
```

### 5.5 Apply + 验证

```bash
kubectl apply -f deploy/k8s-2svc.yaml
kubectl -n mcp rollout status deploy/aws-global --timeout=180s
kubectl -n mcp rollout status deploy/aws-cn     --timeout=180s

# 拿 ALB DNS（刚创建时需要等 1-2 分钟 provision）
kubectl -n mcp get ingress mcp -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'

# 验证 target group 健康
for tg in $(aws elbv2 describe-target-groups --region us-east-1 \
    --query "TargetGroups[?starts_with(TargetGroupName, \`k8s-mcp\`)].TargetGroupArn" --output text); do
  name=$(echo "$tg" | awk -F/ '{print $(NF-1)}')
  state=$(aws elbv2 describe-target-health --region us-east-1 --target-group-arn "$tg" \
    --query 'TargetHealthDescriptions[].TargetHealth.State' --output text)
  echo "  $name: $state"
done

# 端到端握手测试（从集群内，用公共证书）
kubectl -n mcp run curl-verify --rm -i --image=curlimages/curl --restart=Never -q -- sh -c '
curl -sS -m 10 -X POST https://aws-cn.yingchu.cloud/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"clientInfo\":{\"name\":\"v\",\"version\":\"0\"}}}" \
  -w "\nHTTP:%{http_code} / cert_verify=%{ssl_verify_result}\n"
'
```

**期望输出**：
- `HTTP:200`
- `cert_verify=0`（公共 CA 校验通过）
- response body 里有 `"serverInfo":{"name":"AWS-API-MCP","version":"..."}`

---

## 6. Part 4 — 配置 AWS DevOps Agent（坑最多的一步）

### 6.1 创建 Private Connection

Console → DevOps Agent → Capability Providers → Private connections → **Create a new connection**

| 字段 | 值 | 说明 |
|---|---|---|
| Name | `mcp-alb` | 随意 |
| VPC | `vpc-033d9e9955afde81f` | EKS 所在 VPC |
| Subnets | 两个都选 | 每 AZ 一个 ENI，HA |
| IP address type | IPv4 | |
| Security groups | `sg-06a4ed260d90bd259` | ALB 的 SG（允许 443 入）|
| TCP port ranges | 留空 | 默认所有端口 |
| **Host address** ⭐ | **ALB 的 AWS DNS 名**：`internal-k8s-mcp-mcp-*.us-east-1.elb.amazonaws.com` | **不能填 `yingchu.cloud` 的域名 —— 这个字段是给 Lattice 做 DNS 解析用的，必须公网可查**（AWS 的 ELB DNS 在公网查得到，返回私有 IP） |
| Certificate public key | 留空 | 因为用的是 ACM 公共证书，Lattice 默认信任 |

点 Create → 状态 `Create in progress` → 等 ~10 分钟变 `Completed`。

> **⚠️ 最大的坑就在 Host address**。血泪教训详见 [BLOG.md 第 5 节](./BLOG.md#坑5)。

### 6.2 注册 MCP Server

Console → DevOps Agent → Capability Providers → MCP Server → **Register**

| 字段 | 值 |
|---|---|
| Name | `aws-cn-mcp` |
| Endpoint URL | `https://aws-cn.yingchu.cloud/mcp` |
| Enable Dynamic Client Registration | ❌ 不勾（没配 OAuth 发现端点）|
| Connect to endpoint using a private connection | ✅ 勾 |
| Use an existing private connection | 选刚才的 `mcp-alb` |
| Authorization Flow | **API Key** |
| API Key value | 随便填 `placeholder`（MCP Server `AUTH_TYPE=no-auth` 会忽略）|
| API Key header | `Authorization` |
| Encryption | AWS owned key |

> **Endpoint URL 和 Host address 作用不同**：
> - Host address（Private Connection）：给 **Lattice 解析 DNS** 用，必须公网可查
> - Endpoint URL（MCP Server）：只用作 **HTTP `Host:` header 和 TLS SNI**，不做 DNS 解析。所以可以是私有 zone 里的域名

再注册 `aws-global-mcp`，**复用同一条 `mcp-alb` Private Connection**，URL 改成 `https://aws-global.yingchu.cloud/mcp`。

### 6.3 在 Agent Space 里 Add MCP（⚠️ 别漏这步）

**Register ≠ Available**。你在 Capability Providers 里注册的 MCP 只是账户级"上架"，某个具体 Agent Space 要用，必须**显式 Add**。

Console → DevOps Agent → **Agent Space**（你那个 agent）→ **Capabilities** 标签 → **MCP Servers** 区块 → **Add**：

1. 勾 `aws-cn-mcp`、`aws-global-mcp`
2. **Allow all tools**（或按需挑）
3. Save

没做这步，聊天的时候 agent 会 fallback 到内置 `use_aws` 工具，用你控制台登录态的全球区凭证 —— 表面能返回结果但走的根本不是你的 MCP。

### 6.4 端到端验证

Agent Space 聊天框：
```
List EC2 instances in us-east-1
```

**成功信号**：
- 工具名显示类似 `aws-global-mcp___use_aws` 或带你 MCP 前缀的（不是光秃秃的 `use_aws`）
- `kubectl -n mcp logs deploy/aws-global --follow | grep -v "GET /mcp"` 立即刷出 `POST /mcp HTTP/1.1" 200`
- 返回的 EC2 列表来自 `AWS_GLOBAL_AK` 对应的账户，不是你控制台登录的账户

---

## 7. 故障排查

### 7.1 Docker build 失败：`auth.docker.io: i/o timeout`

**症状**
```
ERROR: failed to build: failed to solve: DeadlineExceeded: failed to fetch oauth token: Post "https://auth.docker.io/token": dial tcp 31.13.76.99:443: i/o timeout
```

**原因**：国内网络 DNS 劫持 `auth.docker.io` 到错误 IP（31.13.76.99 属于 Meta 不是 Docker Hub）。

**修复**：Dockerfile 的 FROM 换成 AWS 公共 ECR 镜像
```dockerfile
FROM public.ecr.aws/docker/library/python:3.12-slim
```

### 7.2 pip 依赖冲突

**症状**
```
awslabs.aws-api-mcp-server X.X depends on fastmcp==A.B.C
alibaba-cloud-ops-mcp-server Y.Y depends on fastmcp==D.E.F
ERROR: ResolutionImpossible
```

**修复**：不要在同一个镜像同时装 AWS 和 Aliyun 的 MCP Server 包。拆成两个镜像，或只装需要的。

### 7.3 Pod crash loop，log 里是 supergateway 错误

**症状**：pod 频繁重启，前一容器日志里有
```
Error: No connection established for request ID: 1
    at WebStandardStreamableHTTPServerTransport.send
```

**原因**：supergateway stateless 模式的竞态 bug —— 客户端提前断开时，server 还想回写响应，Node.js 进程未 catch 异常直接退出。

**修复**：**彻底去掉 supergateway**，用 MCP Server 自带的 streamable-http
```yaml
# 改前（❌）
command: ["supergateway"]
args: ["--stdio", "uvx awslabs.aws-api-mcp-server@latest", ...]

# 改后（✅）
command: ["python", "-m", "awslabs.aws_api_mcp_server.server"]
env:
  - { name: AWS_API_MCP_TRANSPORT, value: "streamable-http" }
```

### 7.4 ALB target 一直 unhealthy

**症状**：`describe-target-health` 返回 `unhealthy`，但 pod 本身 Ready，curl localhost:8000 能通。

**原因**：ALB 默认对 `/` 做 HTTP GET 健康检查期望 200，MCP Server 对 `GET /` 返 404、对 `GET /mcp` 返 406。

**修复**：Ingress annotation 加白名单
```yaml
alb.ingress.kubernetes.io/healthcheck-path: "/mcp"
alb.ingress.kubernetes.io/success-codes: "200,404,406"
```

### 7.5 DevOps Agent 注册失败："Could not complete request to provider"

**症状**：Register MCP Server 或 Create Private Connection 报 `ValidationException` + `Could not complete request to provider`。

**原因排查顺序**：

1. **Private Connection 的 Host address 填错了**（最常见）
   - 填的不能是私有 zone 里的域名（公网查不到 → NXDOMAIN → 连接失败）
   - 必须填 **公网可解析** 的 DNS 名。AWS ELB 托管的 DNS 名本身就公网可查但返回私有 IP
   - 改正：Host address 填 `internal-k8s-mcp-mcp-*.us-east-1.elb.amazonaws.com`

2. **自签证书没上传到 Private Connection**
   - "Certificate public key" 字段对自签 CA 是必填（标题说 optional 但下面一行写了"Required if self-signed"）
   - 改正：贴完整 PEM，或换成 ACM 公共证书

3. **Security group 不允许 443 入**
   - 改正：Private Connection 的 SG 要么挂 ALB 的 SG，要么挂个允许 443 outbound 的 SG

4. **Private Connection 还在 Create in progress**
   - 改正：等 10 分钟到 Completed

### 7.6 MCP 返回 `"Session not found"` 错误

**症状**
```json
{"jsonrpc":"2.0","id":"server-error","error":{"code":-32600,"message":"Session not found"}}
```

**原因**：MCP Streamable HTTP 协议在 stateful 模式下维护 session，Pod 副本 > 1 时 ALB round-robin 把请求发到了不同 pod，session 不存在 → 报错。

**修复**（选一个）：
- **快**：`kubectl scale deploy/aws-cn --replicas=1`（放弃 HA）
- **正解**：配 MCP Server 为 stateless 模式（目前 `awslabs.aws-api-mcp-server` 没开这个开关，需要 fork 或等官方支持）
- **绕**：ALB 开 cookie-based sticky session —— 但 MCP session 在 header 不在 cookie，需要 target group 的 `stickiness.lb_cookie` 配合客户端 cookie 支持，DevOps Agent 现在不发 cookie，不可行

### 7.7 Agent 调用但走的是内置 `use_aws`，不是我的 MCP

**症状**：聊天框里返回结果，但：
- 工具名是 `use_aws`（没有我们的 MCP 前缀）
- `kubectl logs` 里**没有 POST /mcp**
- 错误信息带的账户 ID 是**你控制台登录账户**，不是 MCP 配置的 AK 对应账户

**原因**：Agent Space 没 Add 这个 MCP（只在 Capability Providers 注册了，没在 Agent 里启用）。

**修复**：Agent Space → Capabilities → MCP Servers → Add → 勾选 → Allow all tools → Save。

### 7.8 kubectl 报 `Unauthorized`

**症状**：kubectl 所有命令都返回 `You must be logged in to the server (Unauthorized)`。

**原因**：shell 当前 AWS 身份跟 EKS 集群不在同一个账户。比如你 `aws sso login` 换了账户，或者 shell 里被别的进程 `export AWS_PROFILE` 了。

**修复**：
```bash
aws sts get-caller-identity   # 确认当前身份
export AWS_PROFILE=default    # 切回 EKS 所在账户
aws eks update-kubeconfig --region us-east-1 --name mcp-test
```

---

## 8. 文件清单

| 文件 | 作用 |
|---|---|
| `deploy/Dockerfile` | 容器镜像定义（public.ecr.aws base + aws-api-mcp-server） |
| `deploy/k8s-2svc.yaml` | 精简 2 服务版（aws-global + aws-cn），已填实际值 |
| `deploy/k8s.yaml` | 完整 4 服务版（含 aliyun + gcp，未 apply，保留做参考）|
| `terraform/main.tf` | VPC + EKS + LB Controller IRSA |
| `scripts/smoke.sh` | 本地 docker-compose 冒烟测试 |
| `SETUP.md` | 本文档 |
| `BLOG.md` | 配置过程的故事版 |

---

## 9. 清理

```bash
# DevOps Agent（Console 删除，没 CLI）
# Agent Space → 移除 MCP → 删除 MCP Server → 删除 Private Connection

# Kubernetes
kubectl delete -f deploy/k8s-2svc.yaml

# Terraform（会删 EKS + VPC + NAT）
cd terraform && terraform destroy

# Route53 私有 zone
aws route53 list-resource-record-sets --hosted-zone-id Z09231282I798DJM5YYUW
# 先删所有非 NS/SOA 记录，然后：
aws route53 delete-hosted-zone --id Z09231282I798DJM5YYUW

# ECR
aws ecr delete-repository --region us-east-1 --repository-name aws-devops-agent-external-mcp --force

# ACM 导入的自签证书（如果你走过那条路）
aws acm delete-certificate --region us-east-1 --certificate-arn <cert-arn>
```
