# aws-devops-agent-external-mcp

用 **AWS DevOps Agent** 统一管理 AWS 全球区、AWS 中国区、阿里云。

**零业务代码** — 全部使用官方现成 MCP Server，只做部署和接线。

## 架构

```
AWS DevOps Agent (us-east-1)
    │
    │  Private Connection (VPC Lattice)
    ▼
内部 ALB (HTTPS:443, 路径路由)
    │
    ├─ /aws-global/mcp  →  awslabs/aws-api-mcp-server (AK/SK=全球区)
    ├─ /aws-cn/mcp      →  awslabs/aws-api-mcp-server (AK/SK=中国区, region=cn-north-1)
    └─ /aliyun/mcp      →  aliyun/alibaba-cloud-ops-mcp-server (待接入)
```

关键点：
- AWS 中国区和全球区用**同一个** MCP Server 包，只是 AK/SK 和 region 不同
- `supergateway` 把 stdio MCP 转成 **Streamable HTTP**（DevOps Agent 唯一支持的 transport）
- 一个内部 ALB 按路径分流到不同容器，一条 Private Connection 打通

## 目录

```
.
├── README.md
├── docker-compose.yml          # 本地验证（SSE 模式）
├── .env.example                # 三套凭证模板
├── deploy/
│   ├── Dockerfile              # node + supergateway + uv
│   ├── k8s.yaml                # EKS 部署 (Streamable HTTP + HTTPS)
│   └── README.md               # 部署步骤
├── terraform/
│   └── main.tf                 # VPC + EKS + LB Controller IRSA
└── scripts/
    └── smoke.sh                # 本地冒烟测试
```

## 工作原理

### MCP Server 是怎么跑起来的？

每个容器里有两个进程协作：

```
supergateway (Node.js)                 aws-api-mcp-server (Python)
┌──────────────────────┐               ┌──────────────────────┐
│                      │    stdin       │                      │
│  监听 HTTP :8000     │──────────────►│  收到 JSON-RPC 请求   │
│                      │               │  调用 boto3 执行      │
│  POST /aws-cn/mcp    │    stdout     │  aws ec2 describe-*  │
│  ◄──── 转成 HTTP ◄───│◄──────────────│  返回 JSON-RPC 响应   │
│       响应返回        │               │                      │
└──────────────────────┘               └──────────────────────┘
```

**supergateway** 是一个开源 npm 包（[github.com/nichochar/supergateway](https://github.com/nichochar/supergateway)），
作用是把只支持 stdio 的 MCP Server 转成网络可访问的 HTTP 服务。它在 Dockerfile 里通过 `npm install -g supergateway` 预装。

**aws-api-mcp-server** 是 AWS 官方的 MCP Server（[github.com/awslabs/mcp](https://github.com/awslabs/mcp)），
底层是 boto3，能执行几乎所有 AWS CLI 命令。它通过 `uvx`（Python 包运行器，类似 npx）在容器启动时自动下载并运行。

### 为什么需要 supergateway？

AWS DevOps Agent 只支持通过 **Streamable HTTP** 协议连接远程 MCP Server。
但 AWS 官方 MCP Server 只支持 **stdio**（标准输入输出，给本地 Claude Desktop 用的）。
supergateway 做的就是在两者之间当翻译：

```
DevOps Agent ←HTTPS→ ALB ←HTTP→ supergateway ←stdio→ aws-api-mcp-server
```

### 凭证怎么传的？

环境变量注入到容器 → supergateway 继承 → 子进程继承 → boto3 读取：

```yaml
env:
  - name: AWS_DEFAULT_REGION
    value: "cn-north-1"           # boto3 看这个决定调哪个区的 API
  - name: AWS_ACCESS_KEY_ID
    valueFrom:
      secretKeyRef:
        name: mcp-creds
        key: AWS_CN_AK            # 中国区的 Access Key
```

**同一个 MCP Server 包 + 不同的凭证和 region = 管不同的云。**
这就是为什么不需要写任何业务代码。

### k8s.yaml 里那段配置在干什么？

```yaml
command: ["supergateway"]
args:
  - "--stdio"                                    # 用 stdio 启动子进程
  - "uvx awslabs.aws-api-mcp-server@latest"      # 子进程命令（实际的 MCP Server）
  - "--outputTransport"
  - "streamableHttp"                              # 对外暴露 Streamable HTTP
  - "--streamableHttpPath"
  - "/aws-global/mcp"                             # HTTP 路径（ALB 按这个路由）
  - "--port"
  - "8000"                                        # 监听端口
```

## 快速开始

### 1. 本地验证（不需要 EKS）

```bash
cp .env.example .env
# 填入三套 AK/SK（只读权限即可）
vim .env

docker compose up -d

# 测试 SSE 端点
curl -sN http://localhost:8001/sse | head -3   # aws-global
curl -sN http://localhost:8002/sse | head -3   # aws-cn
curl -sN http://localhost:8003/sse | head -3   # aliyun
```

### 2. 部署到 AWS EKS

#### 2a. 创建基础设施

```bash
cd terraform
terraform init && terraform apply -auto-approve
# 输出: cluster_name, vpc_id, public_subnets, lb_controller_role_arn

# 连接集群
$(terraform output -raw kubeconfig_cmd)
```

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

```bash
# 创建 Route53 私有托管区
aws route53 create-hosted-zone \
  --name mcp.internal \
  --caller-reference "mcp-$(date +%s)" \
  --vpc VPCRegion=us-east-1,VPCId=$(terraform output -raw vpc_id) \
  --hosted-zone-config PrivateZone=true

# 生成自签证书（带 FQDN，ALB 要求）
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /tmp/mcp-key.pem -out /tmp/mcp-cert.pem \
  -subj "/CN=mcp.mcp.internal" \
  -addext "subjectAltName=DNS:mcp.mcp.internal"

# 导入 ACM
aws acm import-certificate --region us-east-1 \
  --certificate fileb:///tmp/mcp-cert.pem \
  --private-key fileb:///tmp/mcp-key.pem
# 记下输出的 CertificateArn，替换 k8s.yaml 中的 certificate-arn
```

#### 2d. 部署 MCP 容器

```bash
# 构建推镜像
ECR=<account-id>.dkr.ecr.us-east-1.amazonaws.com/aws-devops-agent
aws ecr create-repository --repository-name aws-devops-agent --region us-east-1
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin $ECR
docker build --platform linux/amd64 -t $ECR:latest -f deploy/Dockerfile .
docker push $ECR:latest

# 替换 k8s.yaml 中的镜像地址和证书 ARN
sed -i '' "s|<ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/aws-devops-agent|$ECR|g" deploy/k8s.yaml
sed -i '' "s|certificate-arn: .*|certificate-arn: <your-cert-arn>|" deploy/k8s.yaml

# 创建凭证 Secret
kubectl create namespace mcp
kubectl -n mcp create secret generic mcp-creds \
  --from-literal=AWS_GLOBAL_AK=<全球区 AK> \
  --from-literal=AWS_GLOBAL_SK=<全球区 SK> \
  --from-literal=AWS_CN_AK=<中国区 AK> \
  --from-literal=AWS_CN_SK=<中国区 SK>

# 部署
kubectl apply -f deploy/k8s.yaml
```

#### 2e. 添加 DNS 记录

```bash
ALB_DNS=$(kubectl -n mcp get ingress mcp -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

aws route53 change-resource-record-sets --hosted-zone-id <zone-id> --change-batch "{
  \"Changes\": [{
    \"Action\": \"UPSERT\",
    \"ResourceRecordSet\": {
      \"Name\": \"mcp.mcp.internal\",
      \"Type\": \"CNAME\",
      \"TTL\": 60,
      \"ResourceRecords\": [{\"Value\": \"$ALB_DNS\"}]
    }
  }]
}"
```

### 3. 配置 AWS DevOps Agent

#### 3a. 创建 Private Connection

控制台 → **DevOps Agent** → **Capability Providers** → **Private connections** → **Create**

| 字段 | 值 |
|---|---|
| Host address | ALB 内部 DNS（`internal-k8s-mcp-*.us-east-1.elb.amazonaws.com`） |
| VPC | EKS 所在 VPC |
| Subnets | 至少 2 个（不同 AZ） |
| TCP port | 443 |

等状态变 `Completed`（约 10 分钟）。

#### 3b. 注册 MCP Server

控制台 → **Capability Providers** → **MCP Server** → **Register**

注册两次：

**aws-global：**

| 字段 | 值 |
|---|---|
| Name | `aws-global` |
| Endpoint URL | `https://mcp.mcp.internal/aws-global/mcp` |
| Description | AWS Global Region MCP |
| Auth | API Key |
| Header name | `x-api-key` |
| API key value | （你生成的 key） |

**aws-cn：**

| 字段 | 值 |
|---|---|
| Name | `aws-cn` |
| Endpoint URL | `https://mcp.mcp.internal/aws-cn/mcp` |
| Description | AWS China Region MCP |
| Auth | API Key（同上） |

#### 3c. 在 Agent Space 关联 MCP

进入 Agent Space → **Capabilities** → **MCP Servers** → **Add** → 选择刚注册的 MCP → Allow all tools → **Add**

### 4. 验证

在 Agent Space 聊天中测试：

```
List all EC2 instances in us-east-1          → 走 aws-global
List all EC2 instances in cn-northwest-1     → 走 aws-cn
List my S3 buckets in cn-north-1             → 走 aws-cn
```

## DevOps Agent 对 MCP Server 的要求

| 要求 | 本方案如何满足 |
|---|---|
| Streamable HTTP transport | `supergateway --outputTransport streamableHttp` |
| HTTPS endpoint | 内部 ALB + ACM 证书 |
| 认证（OAuth / API Key） | API Key header 校验 |
| 私网可达 | Private Connection (VPC Lattice) |

## 添加阿里云

阿里云 MCP Server 已有官方包 `alibaba-cloud-ops-mcp-server`，接入步骤：

1. 在 `k8s.yaml` 中添加第三个 Deployment（参考 aws-cn，改 MCP_CMD 和环境变量）
2. 在 `mcp-creds` Secret 中添加 `ALIYUN_AK` / `ALIYUN_SK`
3. Ingress 添加 `/aliyun` 路径规则
4. 在 DevOps Agent 控制台注册第三个 MCP Server

阿里云国际站用户需加参数 `--env international`。

## 销毁

```bash
kubectl delete -f deploy/k8s.yaml
cd terraform && terraform destroy -auto-approve
```

## 费用估算

| 资源 | 费用 |
|---|---|
| EKS 控制平面 | $0.10/h |
| 1× t3.medium 节点 | $0.04/h |
| 内部 ALB | $0.02/h |
| **合计** | **~$0.16/h ≈ $115/月** |

测完记得销毁。
