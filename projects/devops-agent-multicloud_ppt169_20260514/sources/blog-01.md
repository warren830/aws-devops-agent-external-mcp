# AWS DevOps Agent 接入 AWS 中国区（一）：Partition 隔离与 MCP 单账号桥接

> AWS DevOps Agent 是全球区（`aws` partition）的服务，原生跨不进中国区（`aws-cn` partition）。想让它帮你管中国区账号，得自己把"桥"建起来。本文（系列第一篇）讲清楚**为什么要建、架构长什么样、单账号场景一步步怎么跑到能用**。多账号扩展、跨云接入、凭证轮换在第二篇。

*本仓库：`aws-devops-agent-external-mcp`。本文所有命令、Helm chart、Terraform 模块都在仓库里现成可跑。*

---

## 目录

- [1. 为什么要建这座桥](#1-为什么要建这座桥)
- [2. 整体架构与关键设计](#2-整体架构与关键设计)
- [3. 单账号部署](#3-单账号部署)
- [4. AWS DevOps Agent 侧注册](#4-aws-devops-agent-侧注册)
- [5. 验证 Agent 已联通中国区](#5-验证-agent-已联通中国区)
- [6. 常见问题](#6-常见问题)
- [本系列其他文章](#本系列其他文章)

---

## 1. 为什么要建这座桥

AWS DevOps Agent（具备 Agentic SRE 能力，可协助处理告警分流、根因分析、修复建议）只跑在全球区。其内置的 `use_aws` 工具调用的是 `arn:aws:iam::...` 这种**全球区**身份。

中国区账号的 ARN 是 `arn:aws-cn:iam::...` —— **partition 不同**。全球区颁发的 Access Key 在 `cn-northwest-1` 直接返回 `AuthFailure`。这是 AWS 法律实体级别的隔离，不是配置问题。

<details>
<summary>AuthFailure 示例 — 拿全球区 Access Key 调中国区</summary>

```bash
# 用全球区 profile（账号 034xxxxxx319）去 cn-northwest-1 查 EC2
$ aws ec2 describe-instances --profile default --region cn-northwest-1
An error occurred (AuthFailure) when calling the DescribeInstances operation:
AWS was not able to validate the provided access credentials
```
</details>

所以让 DevOps Agent 处理中国区工作负载，**唯一可行路径**是：自建一个 MCP（Model Context Protocol）Server，由它持有中国区 Access Key，DevOps Agent 通过 MCP 协议调它，它再调中国区 API。MCP 就是那座桥。

> MCP 是 Anthropic 提出的开放协议，用于把外部工具/数据源接入 LLM Agent。AWS DevOps Agent 在 Agent Space 中支持注册外部 MCP Server 作为 capability，调用方式与内置工具一致。本文假设你已了解协议本身。

---

## 2. 整体架构与关键设计
![single-account-arch](01-single-arch.png)


注意：DevOps Agent Runtime、ALB、EKS Pod 都在**同一个全球区账号**内。Private Connection 是 AWS-managed control plane 接入客户 VPC 的标准通道（类似 Bedrock VPC endpoint），不是跨账号桥接。整张图唯一一条**跨 partition** 的箭头是 ③ —— pod 持中国区 Access Key 调用 `*.amazonaws.com.cn`。

### 2.1 关键设计决策

- **Pod 持长期 AK/SK，不走 AssumeRole**：跨 partition 不能 AssumeRole 互通，DevOps Agent 在全球区，调中国区 API 必须用中国区颁发的长期 Access Key。
- **Internal ALB（非 internet-facing）**：DevOps Agent 的 Private Connection 通过 VPC Lattice 实现内网互通，无需暴露公网，扩大攻击面。
- **Health Check Path 设为 `/mcp`**：`awslabs.aws-api-mcp-server` 的 streamable-HTTP 端点仅响应 `/mcp`，根路径返回 404。Health check 直接对准 `/mcp` 比扩展 `success-codes` 更干净。

> 系列第二篇会展开多账号扩展，那时会涉及"为什么不复用同一对 Access Key"的 blast radius 取舍。本文保持单账号视角。

---

## 3. 单账号部署

下面以 AWS 中国区宁夏区域（`cn-northwest-1`）为例。流程对任意中国区账号通用，差异仅在 Helm values 中的 region 与 secret 引用。

### 3.1 前置：Terraform 建基础设施（一次性）

```bash
cd terraform
terraform init
terraform apply
```

Terraform 创建：VPC、EKS Cluster (`mcp-test`)、AWS Load Balancer Controller、ECR Repository、Secrets Manager Secret。

### 3.2 构建并推送容器镜像

```bash
cd ../deploy
# ECR login 然后 build & push
docker buildx build --platform linux/amd64 \
  -t 034xxxxxx319.dkr.ecr.us-east-1.amazonaws.com/aws-devops-agent-external-mcp:latest \
  --push .
```

> 镜像基于 `awslabs.aws-api-mcp-server`（**无需 fork**）。本仓库只在外面包了 Helm chart、Ingress、Secret 注入等部署相关代码，MCP server 本身没有任何代码改动。

### 3.3 部署 Helm Chart

先把中国区 Access Key 写入 Kubernetes Secret：

```bash
kubectl create namespace mcp
kubectl -n mcp create secret generic mcp-aws-cn \
  --from-literal=AWS_ACCESS_KEY_ID=<宁夏账号 AK> \
  --from-literal=AWS_SECRET_ACCESS_KEY=<宁夏账号 SK>
```

> 这是 **Mode A** —— K8s Secret 手工管理，单账号入门最直观。仓库默认实际跑 **Mode B**（External Secrets Operator + AWS Secrets Manager），更适合多账号 + 凭证轮换场景，系列第二篇详述。本文 demo 跟着 Mode A 走即可。

部署 Helm Chart：

```bash
helm install aws-cn ./chart -f ./chart/values-aws-cn.yaml -n mcp
```

`values-aws-cn.yaml` 关键字段（Mode A 版本）：

```yaml
account:
  name: aws-cn
  awsRegion: cn-northwest-1
  host: aws-cn.example.cloud
  existingSecret: mcp-aws-cn
  secretKeys:
    AWS_ACCESS_KEY_ID: AWS_ACCESS_KEY_ID
    AWS_SECRET_ACCESS_KEY: AWS_SECRET_ACCESS_KEY
```

### 3.4 验证部署：3 个命令看出来

```bash
# 1. Pod 在跑
$ kubectl -n mcp get pods
NAME                          READY   STATUS    RESTARTS   AGE
mcp-aws-cn-b8db9b759-hr5th    1/1     Running   0          3h

# 2. Ingress 拿到了 ALB DNS
$ kubectl -n mcp get ingress
NAME         CLASS  HOSTS                  ADDRESS                                 PORTS
mcp-aws-cn   <none> aws-cn.example.cloud   internal-k8s-mcp-xxx.elb.amazonaws.com  80

# 3. 集群内 curl MCP endpoint，应返回 JSON-RPC 响应（不是 connection refused）
$ kubectl -n mcp exec deploy/mcp-aws-cn -- curl -s http://localhost:8000/mcp -X POST \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"tools/list","id":1}'
{"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"call_aws",...}]}}
```

到这一步，单账号 MCP 已是**可从 cluster 内访问的可用服务**。

### 3.5 加一条 CNAME

在你的 DNS 服务（Amazon Route 53、Tencent DNSPod、Cloudflare 等）为子域名加 CNAME，指向上一节得到的 ALB DNS 名：

```
Host:   aws-cn
Target: internal-k8s-mcp-xxx.elb.amazonaws.com
TTL:    300
```

约 5 分钟生效后，从 VPC 内通过 `https://aws-cn.example.cloud/mcp` 可访问 MCP Server。

> ALB scheme 是 `internal` —— 公网无法直接访问。DevOps Agent 通过 VPC Lattice Private Connection 进入这个 VPC 才能联通，下一节配置。

---

## 4. AWS DevOps Agent 侧注册

MCP Server 跑起来只是"桥建好了一半"。另一半是在 **Agent Space 中将其注册为可用 capability**，agent 才知道有这个工具可用。

### 4.1 创建 Private Connection

DevOps Agent 的 Private Connection 是 VPC Lattice 封装出来的内网链路：

1. AWS Console → **AWS DevOps Agent** → 你的 Agent Space
2. **Capabilities** → **Private Connections** → **Add private connection**
3. 填：
   - **Name**: `mcp-internal`
   - **Host address**: ALB 的 DNS 名（`internal-k8s-mcp-xxx.elb.amazonaws.com`）
   - **Port**: `443`
   - **Protocol**: HTTPS

保存后状态由 `PENDING` 转为 `ACTIVE`，通常 1–3 分钟。

### 4.2 添加 MCP Server

**Capabilities** → **MCP Servers** → **Add MCP server**：

- **Name**: `aws-cn`
- **Endpoint**: `https://aws-cn.example.cloud/mcp`
- **Private Connection**: 选刚建的 `mcp-internal`
- **Auth**: No auth

> **为什么 No auth？** 这一层的安全保证由 **Internal ALB** 提供 —— ALB scheme=internal、仅接受来自 VPC Lattice Private Connection 的流量、公网无法访问。MCP Server 内部已用中国区 Access Key 与 AWS API 完成认证，前置鉴权由 ALB 网络层负担，没必要再加一层。

---

## 5. 验证 Agent 已联通中国区

在 Operator Web App（跟 agent 对话的界面）开一个新 chat，发：

> 查询 aws-cn 账号下所有 VPC 的 CIDR

如果 agent：

- 顶部状态栏显示 **"1 tool used"**（即 `aws-cn` MCP）
- 输出正确的 VPC 列表，**且明确标注是 aws-cn 账号**

—— 桥已联通。

如果 agent 回复"无法访问 aws-cn 账号"，或试图用全球区身份调用并报 `AuthFailure`，说明 Private Connection 或 MCP Server 注册有问题，回到 §4 排查。

> 让 agent 能自然地"知道用户问的是哪个账号、用什么格式输出对比表"，是 **Skills** 的工作 —— 不是 MCP 这一层能解决的。系列第三篇专门讲 Skills 怎么写。本文只验证最基础的"agent 能不能调到中国区 API"。

---

## 6. 常见问题

**Pod 内 curl 测试就报 `AuthFailure`** — Secret 里写的是全球区 AK/SK，不是中国区颁发的。验证：

```bash
kubectl -n mcp exec deploy/mcp-aws-cn -- env | grep AWS_ACCESS_KEY_ID
```

对照 IAM 控制台确认 partition 归属（中国区 IAM 用户只能在 [console.amazonaws.cn](https://console.amazonaws.cn) 看到）。

**ALB Target Unhealthy** — Health check path 没指向 `/mcp`，default `success-codes` 仅识别 2xx，根路径 404 被判失败。values 里把 `healthcheckPath` 设成 `/mcp`，或扩展 `success-codes: 200,404,405,406`。

**Private Connection 状态 `UNAVAILABLE`** — ALB scheme 是 internet-facing 而非 internal；或 Security Group 没放通 443。检查：

```bash
kubectl -n mcp get ingress mcp-aws-cn -o yaml | grep scheme
```

应为 `internal`。

**`docker build` 报 `dial tcp 31.13.76.99:443: i/o timeout`** — Docker Hub 在国内被 DNS 污染到 Meta CDN IP。改 `/etc/hosts` 或用国内镜像源代理。

**Helm install 后 pod `ImagePullBackOff`** — ECR 镜像 push 没完成；或 EKS NodeGroup IAM 没授权拉 ECR。`aws ecr describe-images` 确认 image 存在；NodeGroup IAM Role 需有 `AmazonEC2ContainerRegistryReadOnly` 策略。

---

## 本系列其他文章

- **《AWS DevOps Agent 接入 AWS 中国区（二）：多账号扩展、跨云接入与凭证轮换》**（[02-multi-account-extension.md](02-multi-account-extension.md)）—— 在本文单账号架构基础上，讲一个 Helm Chart 管理 N 个中国区账号、ALB Ingress group 共享、阿里云为什么单独打包、Mode B (ESO + Secrets Manager) 怎么搭、90 天凭证轮换的 8 步流程。
- **《AWS DevOps Agent 接入 AWS 中国区（三）：8 个 Skill 让 Agent 真正懂你的多账号场景》**（[03-skills-in-action.md](03-skills-in-action.md)）—— MCP 给的是能力（tools 可调用），Skills 给的是策略（什么场景调什么、怎么组织输出、什么时候停下等人 approve）。8 个 skill 的三层架构、description 触发词设计、Incident Pipeline 全流程实战。
