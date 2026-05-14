# AWS DevOps Agent 接入 AWS 中国区（二）：多账号扩展、跨云接入与凭证轮换

> 第一篇讲了单账号怎么把桥搭起来。本文展开**多账号扩展、跨云接入、凭证轮换**三件事 —— 都是入了 AWS DevOps Agent + 中国区生产环境后必然遇到的工程现实。

*前置：[01-single-account-bridge.md](01-single-account-bridge.md) — 单账号桥接架构。本文的所有部署逻辑都建立在第一篇的 EKS + ALB + Helm chart 之上。*

---

## 目录

- [1. 多账号架构：一 chart × N values](#1-多账号架构一-chart--n-values)
- [2. 加第二个账号：3 步 checklist](#2-加第二个账号3-步-checklist)
- [3. 验证 Agent 真的在用两个账号](#3-验证-agent-真的在用两个账号)
- [4. ALB Ingress Group 共享：一个 ALB 管 N 个 host](#4-alb-ingress-group-共享一个-alb-管-n-个-host)
- [5. 备选架构：方案 B — 1 pod 多账号](#5-备选架构方案-b--1-pod-多账号)
- [6. 跨云扩展 — 阿里云为什么要独立 chart](#6-跨云扩展--阿里云为什么要独立-chart)
- [7. Mode B：ESO + Secrets Manager](#7-mode-beso--secrets-manager)
- [8. 凭证轮换：90 天 8 步流程](#8-凭证轮换90-天-8-步流程)
- [9. 加第 N 个账号 Checklist](#9-加第-n-个账号-checklist)
- [本系列其他文章](#本系列其他文章)

---

## 1. 多账号架构：一 chart × N values

第一篇里我们用单账号 Helm Chart 跑通了 `aws-cn`。多账号场景的核心思路：**同一个 chart，每个账号一份 values 文件**。
![img.png](02-multi-account-arch.png)


注意：

- **每账号一个独立 Pod，持自己 partition + 自己账号的 AK/SK**。账号是 blast radius 边界，region 不是。即便两个账号都在同一个 region，也必须各自一个 Pod —— 凭证不能共享。
- **一个 ALB 管所有 host**：`alb.ingress.kubernetes.io/group.name: mcp` 这一个注解让 ALB Controller 把多个 Ingress 合并到同一个 ALB，每加账号不多收一个 ALB 的钱（约 $16/月）。
- **DevOps Agent 一条 Private Connection 接所有 MCP**：Private Connection 通的是 ALB，不是单个 Pod。N 个 MCP 共用 1 个 Connection，加账号只是多加一条 MCP Server 注册。

### Chart 结构

```
chart/
├── values.yaml             # 全局默认（image / resources / ingress group / ...）
├── values-aws-cn.yaml      # aws-cn 账号覆盖
├── values-aws-cn-2.yaml    # aws-cn-2 账号覆盖
├── values-aws-global.yaml  # 全球区账号覆盖（可选）
└── templates/
    ├── deployment.yaml
    ├── service.yaml
    ├── ingress.yaml
    └── externalsecret.yaml
```

`values.yaml` 是**全局默认**（image、resources、namespace、ingress group 名）。每个账号的覆盖在 `values-<account>.yaml`，**只写跟默认不一样的东西**。

对比两个账号的 values，差异只有 4 行：

```bash
$ diff chart/values-aws-cn.yaml chart/values-aws-cn-2.yaml
< account:
<   name: aws-cn
<   awsRegion: cn-northwest-1
<   host: aws-cn.example.cloud
<   existingSecret: mcp-aws-cn
---
> account:
>   name: aws-cn-2
>   awsRegion: cn-north-1
>   host: aws-cn-2.example.cloud
>   existingSecret: mcp-aws-cn-2
```

**4 行差异，加一个账号**。这就是 Helm chart 模板化的价值 —— 加账号边际成本趋近于 0。

---

## 2. 加第二个账号：3 步 checklist

```bash
# 1. K8s Secret（北京账号的 AK/SK）
kubectl -n mcp create secret generic mcp-aws-cn-2 \
  --from-literal=AWS_ACCESS_KEY_ID=<北京 AK> \
  --from-literal=AWS_SECRET_ACCESS_KEY=<北京 SK>

# 2. Helm install（复用同一个 chart）
helm install aws-cn-2 ./chart -f ./chart/values-aws-cn-2.yaml -n mcp

# 3. DNS 加 CNAME（aws-cn-2.example.cloud → ALB DNS 名）
#    注意 target 是同一个 ALB DNS —— group.name: mcp 决定了
#    Controller 把两个 Ingress 合并到同 1 个 ALB，两个子域解析到同地址
```

完事。实测从写 values 到 pod ready：**4 分钟**。

### 验证两个账号都在工作

```bash
$ kubectl -n mcp get all
NAME                                READY   STATUS    RESTARTS   AGE
pod/mcp-aws-cn-2-7b975bbd74-9ghz7   1/1     Running   0          3h10m
pod/mcp-aws-cn-b8db9b759-hr5th      1/1     Running   0          3h11m

NAME                   TYPE        CLUSTER-IP       PORT(S)
service/mcp-aws-cn     ClusterIP   172.20.79.63     8000/TCP
service/mcp-aws-cn-2   ClusterIP   172.20.247.172   8000/TCP

NAME                           READY   UP-TO-DATE   AVAILABLE
deployment.apps/mcp-aws-cn     1/1     1            1
deployment.apps/mcp-aws-cn-2   1/1     1            1
```

两个 pod、两个 service、两个 deployment，**但只有一个 ALB**：

```bash
$ kubectl -n mcp get ingress -o wide
NAME           HOSTS                    ADDRESS
mcp-aws-cn     aws-cn.example.cloud     internal-k8s-mcp-xxx.elb.amazonaws.com
mcp-aws-cn-2   aws-cn-2.example.cloud   internal-k8s-mcp-xxx.elb.amazonaws.com
```

两个 Ingress 的 ADDRESS 字段是**同一个** ALB DNS 名 —— 这是 ingress group 的功劳。

### Agent Space 侧

回到 Agent Space → **Capabilities** → **MCP Servers** → **Add MCP server**：

- **Name**: `aws-cn-2`
- **Endpoint**: `https://aws-cn-2.example.cloud/mcp`
- **Private Connection**: **复用第一篇建的那个** `mcp-internal`（不需要新建）

> 这里是多账号架构最体感的设计：**一条 Private Connection 接所有 MCP Server**。Private Connection 是面向 ALB 的通道，不是面向单个 Pod 的。如果未来你有 5 个 AWS 账号 + 阿里云 + GCP，都能用同一个 Connection。加账号只是多加一条 MCP Server 记录。

---

## 3. 验证 Agent 真的在用两个账号

第一篇的验证只问了"查 aws-cn 的 VPC"，确认单个 MCP 通了即可。多账号场景的验证升级为：**让 agent 同时调到两个 MCP，且对结果按账号正确归属**。

在 Operator Web App 开新 chat，发：

> 对比 aws-cn 和 aws-cn-2 两个账号的 VPC CIDR

期望看到的信号：
![img.png](02-multi-arch.png)
- 顶部状态栏 **"2 tools used"** —— agent 并行调了 `aws-cn` MCP 一次、`aws-cn-2` MCP 一次
- 输出是 markdown 对比表，**每行明确标注账号归属**（aws-cn 的 VPC vs aws-cn-2 的 VPC）
- 右上角调用列表显示两个 MCP 同时 running，不是先后

如果 agent 只调了一个账号，或返回的 VPC 列表没有账号 attribution —— 不是 MCP 层的问题，是 **Agent Skills（routing skill）没设计好**。系列第三篇会专门讲怎么写 routing skill 让 agent 自动按用户 query 选账号、并行调用、归属输出。

> 本文只负责验证"两个 MCP 都已注册成功且 agent 能调到"。让 agent **自然地**理解"用户问的是哪个账号"是 Skills 的工作，不在本文范围内。

---

## 4. ALB Ingress Group 共享：一个 ALB 管 N 个 host

`kubectl describe ingress` 看一下设计决策落地的样子：

```bash
$ kubectl -n mcp describe ingress mcp-aws-cn | head -30
Name:             mcp-aws-cn
Namespace:        mcp
Address:          internal-k8s-mcp-xxx.elb.amazonaws.com
Rules:
  Host                  Path   Backends
  aws-cn.example.cloud  /      mcp-aws-cn:8000 (10.42.158.159:8000)
Annotations:
  alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:us-east-1:034xxxxxx319:certificate/74d2cea3-...
  alb.ingress.kubernetes.io/group.name: mcp
  alb.ingress.kubernetes.io/healthcheck-path: /mcp
  alb.ingress.kubernetes.io/listen-ports: [{"HTTPS":443}]
  alb.ingress.kubernetes.io/scheme: internal
  alb.ingress.kubernetes.io/ssl-policy: ELBSecurityPolicy-TLS13-1-2-2021-06
  alb.ingress.kubernetes.io/success-codes: 200,404,405,406
  alb.ingress.kubernetes.io/target-type: ip
```

3 个关键决策：

- **`certificate-arn` 是 wildcard cert `*.example.cloud`** → 同一个 cert 管所有子域，加账号不用申请新 cert
- **`group.name: mcp`** → 多 ingress 合并到 1 个 ALB
- **`success-codes: 200,404,405,406`** → MCP server health check 兼容（详见第一篇 §6）

---

## 5. 备选架构：方案 B — 1 pod 多账号

§1 的架构是 **N pods × N AK/SK**：blast radius 缩到每账号独立，但代价是 N 对长期凭证要轮换。账号数 ≥ 5 时，凭证管理成本会盖过 blast radius 带来的安全收益。这时**方案 B** 值得考虑。

> 第一篇 §2 提过：**同 partition 跨账号 AssumeRole 在技术上完全可行**，本仓库当前架构选择不走这条路是出于 blast radius 考虑。方案 B 就是利用这一点。

重点：**方案 B 零代码改动**。我最初以为要 fork `awslabs.aws-api-mcp-server` 写 middleware，**这是错的**。真实做法就是利用 boto3 原生的 profile chain。

### 方案 B 的做法

**1. `~/.aws/credentials` + `~/.aws/config` 写成 profile chain：**

```ini
# credentials
[source]
aws_access_key_id     = <aws-cn 账号的长期 AK>
aws_secret_access_key = <aws-cn 账号的长期 SK>
```

```ini
# config
[profile aws-cn]
region = cn-northwest-1
# 不 AssumeRole，直接用 source 的长期凭证

[profile aws-cn-2]
region         = cn-north-1
role_arn       = arn:aws-cn:iam::<aws-cn-2-account-id>:role/MCPCrossAccountRole
source_profile = source
external_id    = <约定好的 UUID>
```

**2. K8s Secret 把这两个文件 mount 到 pod 的 `~/.aws/`：**

```yaml
# chart/templates/deployment.yaml 改一处
volumes:
  - name: aws-config
    secret:
      secretName: mcp-aws-multi-account
volumeMounts:
  - name: aws-config
    mountPath: /root/.aws
    readOnly: true
```

**3. aws-cn-2 账号里建 Role，trust aws-cn 账号 + ExternalId：**

```bash
# 在 aws-cn-2 账号里跑
aws iam create-role \
  --profile aws-cn-2-admin --region cn-north-1 \
  --role-name MCPCrossAccountRole \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {"AWS": "arn:aws-cn:iam::<aws-cn-account-id>:user/mcp-source"},
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": {"sts:ExternalId": "<那个 UUID>"}
      }
    }]
  }'

aws iam attach-role-policy \
  --profile aws-cn-2-admin --region cn-north-1 \
  --role-name MCPCrossAccountRole \
  --policy-arn arn:aws-cn:iam::aws:policy/ReadOnlyAccess
```

**4. agent 调 MCP 时命令里带 `--profile`：**

```
aws ec2 describe-instances --profile aws-cn-2 --region cn-north-1
```

`awslabs.aws-api-mcp-server` 的 `call_aws` 工具透传命令参数给 AWS CLI，CLI 内部走 boto3 profile chain。**Server 本身不用改**。

### Routing skill 要跟着改

方案 B 下，agent 不是"选 MCP endpoint"，是"选 `--profile` 参数"。所以 `china-region-multi-account-routing` skill 的规则从：

```
aws-cn queries  → call MCP at aws-cn.example.cloud
aws-cn-2 queries → call MCP at aws-cn-2.example.cloud
```

变成：

```
aws-cn queries  → call MCP with command: `aws ... --profile aws-cn`
aws-cn-2 queries → call MCP with command: `aws ... --profile aws-cn-2`
```

同样是"告诉 agent 用哪个 identifier"，identifier 从 MCP host 变成 CLI profile 名。

### 三套方案并排对比

| 维度 | **当前：N pods × 独立 AK** | **方案 A：N pods + mount `~/.aws`** | **方案 B：1 pod + profile 路由** |
|---|---|---|---|
| pods 数量 | N | N | 1 |
| 长期 AK/SK 对数 | N 对 | 1 对 | 1 对 |
| 1 对 AK 泄漏的影响 | **1 个账号** | **所有 N 个账号** | **所有 N 个账号** |
| 每次调用是否多一次 STS | 无 | 有（~200ms） | 有（同 A） |
| 代码改动 | 零 | 零 | 零 |
| 部署改动 | 当前 | K8s Secret schema 改 | K8s Secret + 合并 values + 改 routing skill |
| 何时值得 | ≤ 5 个账号 | 合规要求长期凭证最小化，又想保留 pod 级隔离 | ≥ 10 个账号，凭证管理成主要痛点 |

### 本仓库为什么不选方案 B？

**因为只有 2 个账号**。维护 2 对 AK/SK = 每 90 天两次 `put-secret-value`，可接受。同时 blast radius 缩到每账号独立 —— 这是当前规模下的安全偏好。

账号数 5+ 时这个取舍会反转。

---

## 6. 跨云扩展 — 阿里云为什么要独立 chart

仓库里有两个 chart 目录：

```
chart/          # AWS MCP（所有 AWS 账号共用）
chart-aliyun/   # Aliyun MCP（单独）
```

### 为什么拆？不能复用吗？

**依赖冲突**。AWS MCP 用的 `awslabs.aws-api-mcp-server` 内部依赖 `boto3 >= 1.35`；Aliyun 用的 `alibaba-cloud-ops-mcp-server` 依赖 `fastmcp`，而 `fastmcp` pin 了 `mcp == 1.2.x` —— 跟 `boto3` 的传递依赖有版本冲突。

实际装的时候会看到：

```
ERROR: Cannot install awslabs-aws-api-mcp-server and fastmcp because these
package versions have conflicting dependencies.
The conflict is caused by:
  fastmcp 0.x.y depends on mcp==1.2.*
  awslabs-aws-api-mcp-server 0.x.y depends on mcp>=1.3
```

解决路径有三条：
- (a) 同一个 image 装两套 virtualenv —— 镜像 2x 大，运维复杂
- (b) 升级其中一个 —— 跟上游 release 节奏走，出 bug 还要帮 upstream 调
- (c) **拆两个 chart，每个 chart 自己的 image** —— 各自的依赖树 pin 在自己 image 里，升级互不牵连

本仓库选 (c)。代价是多一个 `chart-aliyun/` 目录、多维护一份 Dockerfile，但收益是**升级解耦**。

### chart 间的关系

两个 chart 的 templates 几乎一样（Deployment / Service / Ingress / ExternalSecret），差异只在 image 和 secret 注入方式。Aliyun MCP 期望的 env var 不是 `AWS_ACCESS_KEY_ID` 而是 `ALIBABA_CLOUD_ACCESS_KEY_ID`，所以 `chart-aliyun/values.yaml` 里 `account.extraEnv` 注入这些。

> 跨云架构里 ALB / ingress group / Private Connection 全都复用 —— DevOps Agent 看到的就是多一个 host (`aliyun-prod.example.cloud`)。从 Agent Space 视角，跟加 AWS 账号是同一种操作。

---

## 7. Mode B：ESO + Secrets Manager

第一篇为了入门简单，用了 **Mode A**（手工 `kubectl create secret`）。本仓库实际默认跑的是 **Mode B**：

- **Source of truth** 在 AWS Secrets Manager（`/mcp/aws-cn`、`/mcp/aws-cn-2`）
- **External Secrets Operator (ESO)** 每小时从 Secrets Manager 同步到 K8s Secret
- Pod 通过 envFrom 读 K8s Secret —— 无感知 source

### 为什么生产用 Mode B？

| 维度 | Mode A（手工 K8s Secret） | Mode B（ESO + Secrets Manager） |
|---|---|---|
| 凭证存哪 | etcd（K8s 内部） | Secrets Manager（AWS 托管 KMS 加密） |
| 谁有权限读 | 任何有 namespace `secrets get` 的 RBAC user | IAM Policy + KMS Key Policy 双层授权 |
| 审计 | 看不到谁读了 | CloudTrail `GetSecretValue` 全程审计 |
| 轮换 | 改 K8s Secret + restart pod | 改 Secrets Manager 一处，ESO 自动同步 |
| 多 cluster | 各 cluster 各自一份 | 多 cluster 共享 source of truth |
| 学习成本 | 0 | 装 ESO + 配 ClusterSecretStore |

**单账号入门用 Mode A，账号数 ≥ 2 或上生产，强烈建议切 Mode B**。轮换流程下面立刻用得上。

### Mode B 的 values 长什么样

```yaml
# chart/values-aws-cn.yaml (Mode B 版本)
account:
  name: aws-cn
  awsRegion: cn-northwest-1
  host: aws-cn.example.cloud
  secretsManagerKey: /mcp/aws-cn   # Secrets Manager 路径

externalSecrets:
  enabled: true
  secretStoreName: aws-secrets-manager
```

ESO 期望 Secrets Manager 里的 secret value 是 JSON 结构：

```json
{ "AK": "AKIA...", "SK": "..." }
```

ESO 会把这个 JSON 提取成 K8s Secret 里的两个 key（`AK` / `SK`），chart 模板再 map 到容器的 `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` env var。

---

## 8. 凭证轮换：90 天 8 步流程

AWS 推荐 IAM access key 最长 90 天轮换一次。Mode B 下唯一的 source of truth 在 Secrets Manager —— **不要碰 K8s Secret**，它是 ESO 派生的副本，手改会被覆盖。

```bash
# 1. 在中国区 IAM 控制台新建一对 AK/SK（旧的暂时不删，保留 rollback 余地）

# 2. 更新 Secrets Manager 里的 secret value
aws secretsmanager put-secret-value \
  --secret-id /mcp/aws-cn \
  --secret-string '{"AK":"<新 AK>","SK":"<新 SK>"}' \
  --profile default --region us-east-1

# 3. 等 ESO 下一次 sync（默认 refreshInterval: 1h），或手动强制立刻同步
kubectl -n mcp annotate externalsecret mcp-aws-cn \
  force-sync=$(date +%s) --overwrite

# 4. 确认 K8s Secret 已更新
kubectl -n mcp get externalsecret mcp-aws-cn \
  -o jsonpath='{.status.refreshTime}{"\n"}{.status.conditions[0].lastTransitionTime}'

# 5. 重启 pod 让它重新读 Secret 里的 env var
#    (K8s 不会自动 restart pod 来 re-inject 新 env；这步 Mode A/B 都必须)
kubectl -n mcp rollout restart deploy/mcp-aws-cn
kubectl -n mcp rollout status deploy/mcp-aws-cn --timeout=2m

# 6. 跑一次 agent 查询验证新凭证工作（chat 里发"查 aws-cn 的 VPC"）

# 7. 在 IAM 控制台 deactivate 旧 key（不是立即删，先 deactivate 观察 24h）

# 8. 24h 没问题再删旧 key
```

> **为什么 `kubectl annotate` 这招能强制 sync？** ESO controller 把 annotation 变化也当作 reconcile trigger —— 改任何 annotation（哪怕无意义的 `force-sync: <timestamp>`），都能让它立即拉 Secrets Manager 最新值，不用等 `refreshInterval`。

### Mode A 下怎么轮换？

如果你的 `values-<account>.yaml` 把 `externalSecrets.enabled` 设为 `false`，步骤变成：

```bash
# 直接更新 K8s Secret
kubectl -n mcp create secret generic mcp-aws-cn \
  --from-literal=AWS_ACCESS_KEY_ID=<新 AK> \
  --from-literal=AWS_SECRET_ACCESS_KEY=<新 SK> \
  --dry-run=client -o yaml | kubectl apply -f -

# Restart pod
kubectl -n mcp rollout restart deploy/mcp-aws-cn
```

代价：Secrets Manager 不再是 source of truth，多 cluster / 审计 / KMS 加密都没了。账号数多了一定要切 Mode B。

---

## 9. 加第 N 个账号 Checklist

```
[ ] 在新账号的 IAM 里建专用 user + AK/SK（只给 MCP 用）
[ ] 选一个 <host> 名（e.g. aws-cn-prod / aws-cn-gov）
[ ] (Mode B) Secrets Manager 建 /mcp/<host>，值是 {"AK":"...","SK":"..."}
[ ] 复制 chart/values-aws-cn.yaml → values-<host>.yaml，改 4 行
[ ] (Mode A) kubectl create secret mcp-<host>
[ ] helm install <host> ./chart -f values-<host>.yaml -n mcp
[ ] kubectl get pod 确认 running
[ ] DNS 加 CNAME <host>.example.cloud → ALB DNS
[ ] 等 DNS 生效（~5 min）
[ ] DevOps Agent Console 加 MCP Server（Endpoint: https://<host>.example.cloud/mcp，
    Private Connection 复用现有的 mcp-internal）
[ ] 在 chat 里发"查 <host> 的 EC2"验证
```

**熟练后全流程 5–10 分钟**。

---

## 本系列其他文章

- **《AWS DevOps Agent 接入 AWS 中国区（一）：Partition 隔离与 MCP 单账号桥接》**（[01-single-account-bridge.md](01-single-account-bridge.md)）—— 为什么要建桥（partition 隔离）、整体架构、单账号 EKS + ALB + Helm Chart 部署、Agent Space 注册流程。
- **《AWS DevOps Agent 接入 AWS 中国区（三）：8 个 Skill 让 Agent 真正懂你的多账号场景》**（[03-skills-in-action.md](03-skills-in-action.md)）—— MCP 给的是能力（tools 可调用），Skills 给的是策略（什么场景调什么、怎么组织输出、什么时候停下等人 approve）。8 个 skill 的三层架构、description 触发词设计、Incident Pipeline 全流程实战。
