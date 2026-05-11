# 把 AWS DevOps Agent 接到私网 MCP Server：一场 7 层故障面的拆解

> 一次本该 30 分钟的配置，花了整整一下午 —— 因为 README 上每一步看起来都对的配置，在实际链路里每一层都有坑。本文把这些坑按遇到的顺序串起来，每一个都说清楚：**症状是什么、根因在哪、怎么判断、最终怎么修**。

---

## 背景：为什么要干这个

AWS DevOps Agent 是 Amazon 新推出的 always-on SRE Agent，能接管告警、做 RCA、执行 SRE 任务。它自带一部分 AWS 能力（通过内置 `use_aws` 工具），但要接 **私有内部系统**（自建 MCP Server、内网 Grafana、公司内部 GitHub Enterprise 等）就得走**自建 MCP Server + Private Connection** 的路子。

我的目标很简单：

- 在 EKS 上跑两个 MCP Server：一个配**全球区 AK/SK**（`aws-global`），一个配**中国区 AK/SK**（`aws-cn`）
- 用一个内部 ALB + host-based routing 分流
- 走 VPC Lattice Private Connection 给 DevOps Agent 用
- 不需要业务代码，全部用官方 MCP Server 包 + K8s 配置

架构图：
```
AWS DevOps Agent ──Private Connection──→ Internal ALB ──host-based routing──┬─→ aws-global Pod (全球区 AK)
                                            (HTTPS:443)                     └─→ aws-cn     Pod (中国区 AK)
```

看起来一条线到底。但真实世界不是这样。

---

## 坑 1：Supergateway 在 stateless 模式下会 crash 整个进程

### 症状

第一版部署后 pod 跑起来，但用 DevOps Agent 注册时 MCP Server 立即崩溃重启。`kubectl logs --previous` 看到：

```
Error: No connection established for request ID: 1
    at WebStandardStreamableHTTPServerTransport.send
    at ...node:internal/stream_base_commons:191:23
Node.js v20.20.2
```

pod RESTARTS 从 0 跳到 1，DevOps Agent UI 一直转圈然后报 "Could not complete request to provider"。

### 根因

我用的旧架构是 **supergateway** 当 stdio→HTTP 协议桥 —— MCP Server 是 Python 写的 stdio 进程，supergateway（Node.js）在外面包一层 Streamable HTTP。问题出在 `Running stateless server` 模式下：

1. Client 发 `initialize` → supergateway 转发到 stdio 子进程
2. 子进程返回响应 → supergateway 往 HTTP 写回
3. **但此时 client 已经断开了**（DevOps Agent 做 handshake 很快就结束单次连接）
4. `send()` 发现连接不存在，`throw Error`
5. 这个 error 一路冒泡到 top-level，Node.js 进程没 catch，直接退出

每次 DevOps Agent 尝试注册都能触发一次 crash —— 所以注册永远失败。

### 修复

彻底去掉 supergateway。`awslabs.aws-api-mcp-server` 自身就支持 Streamable HTTP，一个环境变量开启：

```yaml
# 改前（❌ 用 supergateway 做协议桥）
command: ["supergateway"]
args:
  - "--stdio"
  - "uvx awslabs.aws-api-mcp-server@latest"
  - "--outputTransport"
  - "streamableHttp"
  - "--streamableHttpPath"
  - "/aws-cn/mcp"

# 改后（✅ 原生 streamable-http）
command: ["python", "-m", "awslabs.aws_api_mcp_server.server"]
env:
  - { name: AWS_API_MCP_TRANSPORT, value: "streamable-http" }
  - { name: AWS_API_MCP_HOST,      value: "0.0.0.0" }
  - { name: AWS_API_MCP_PORT,      value: "8000" }
```

### 教训

**少一层中间件 = 少一层故障面**。每次在"协议 A → 协议 B"中间加东西，就多一个 bug 来源。现在 MCP Server 标准化 Streamable HTTP 之后，`supergateway` 这类工具的必要性大幅降低 —— 有 native 就别用桥。

---

## 坑 2：Docker Hub 在国内 DNS 被污染到 Meta 的 IP

### 症状

`docker build` 过程中

```
ERROR: failed to build: failed to solve: DeadlineExceeded:
failed to fetch oauth token: Post "https://auth.docker.io/token":
dial tcp 31.13.76.99:443: i/o timeout
```

`31.13.76.99` 是 **Facebook/Meta 的 CDN IP** —— 跟 `auth.docker.io` 八竿子打不着。明显 DNS 污染。

### 根因

国内很多 ISP 对 Docker Hub 的域名做劫持，返回错误 IP。就算 Docker Desktop 正常登录了，每次构建时解析 `auth.docker.io` 拿错 IP，尝试连接超时。

### 修复

**换成 AWS 公共 ECR 镜像**：AWS 维护了 Docker Hub 官方镜像的完整镜像在 `public.ecr.aws/docker/library/*`，不需要登录、不经过 Docker Hub 的 auth 服务、从国内访问稳定。

```dockerfile
# 改前
FROM python:3.12-slim

# 改后
FROM public.ecr.aws/docker/library/python:3.12-slim
```

其他改动：零。剩下的 `RUN pip install` 不受影响（pip 走 PyPI，通常国内可达）。

### 教训

在 AWS 生态里构建镜像，**优先用 public.ecr.aws 而不是 docker.io**。理由不光是国内网络 —— ECR 对 AWS 的各种认证路径都更顺畅，拉取速度在 AWS 区域内也更快。

---

## 坑 3：pip 依赖冲突 —— AWS MCP 和 Aliyun MCP 不能共存

### 症状

```
awslabs.aws-api-mcp-server 1.3.33 depends on fastmcp==...
alibaba-cloud-ops-mcp-server 0.9.27 depends on fastmcp==2.8.0
ERROR: ResolutionImpossible
```

### 根因

两个包都依赖 `fastmcp`（FastMCP 是 Python MCP Server 的主流框架），但它们 pin 的版本不一样。pip 没法同时满足。

### 修复

最干净的做法是**拆成两个镜像**，一个装 AWS 的 MCP Server、一个装 Aliyun 的。容器本来就该小而专一。不要 a one-size-fits-all 的全能镜像。

对我的场景来说更简单 —— 用户阶段性只要 AWS 支持，直接从 Dockerfile 里删掉 `alibaba-cloud-ops-mcp-server`：

```dockerfile
# 改前
RUN pip install --no-cache-dir \
      "awslabs.aws-api-mcp-server==${AWS_MCP_VERSION}" \
      "alibaba-cloud-ops-mcp-server==${ALIYUN_MCP_VERSION}"

# 改后
RUN pip install --no-cache-dir \
      "awslabs.aws-api-mcp-server==${AWS_MCP_VERSION}"
```

### 教训

"一个镜像跑多个 MCP Server"看起来能省资源，但第一个跳出来的就是**依赖冲突**。MCP 生态还很年轻，各家 SDK 更新节奏不一样，版本约束经常打架。一个 MCP Server = 一个镜像，干净。

---

## 坑 4：ALB target 一直 unhealthy，但 pod 完全正常

### 症状

Pod Ready 1/1，`curl localhost:8000/mcp` 能返回 406（正常），但 ALB 显示 target unhealthy，访问 ALB 返回 503。

### 根因

ALB 默认健康检查是 `HTTP GET /` 期望返回 200。但 MCP Server 的行为：

```
GET /         → 404
GET /mcp      → 406 (Not Acceptable, 因为缺少 MCP 必需的 Accept header)
GET /health   → 404
GET /healthz  → 404
```

**aws-api-mcp-server 没有任何 /healthz 端点**。所以无论健康检查打到哪个 path，ALB 拿到的都是 4xx，判定不健康。

### 修复

让 ALB 把 4xx 也当"活着"：

```yaml
annotations:
  alb.ingress.kubernetes.io/healthcheck-path: "/mcp"
  alb.ingress.kubernetes.io/success-codes: "200,404,406"
```

判断逻辑："只要 TCP 能连上并且服务器能返回任何 HTTP 响应，说明进程是活的"。这已经足够排除 pod 崩溃 / 端口未监听 等实际故障。

### 教训

**服务器设计时留一个 `/healthz`** —— 多一个路由，几行代码，省的不是运维配置时间而是将来跨团队对接的沟通成本。如果用的是别人的服务器（像我这里），ALB 的 `success-codes` 是个万能的逃生通道。

---

## 坑 5：Private Connection 的 Host address —— 整场最大的坑

### 症状

所有网络层调试都正常：

- 集群内 curl `https://aws-cn.yingchu.cloud/mcp` 返回 200 + 正确 MCP initialize 响应，`cert_verify=0`（证书链完整）
- ALB target group 全 healthy
- VPC Lattice Resource Gateway 状态 ACTIVE
- 证书切换成公共 ACM 证书 `*.yingchu.cloud`，免去自签信任问题
- Private Connection 名字正确、SG 正确、Subnet 正确

但**只要一点 Register MCP Server，就立刻返回 ValidationException**：

```json
{ "message": "An error occurred while trying to access resources from the external service provider.\nCould not complete request to provider." }
```

试了三次，三条新 Private Connection，错误分毫不差。

### 根因

我一直误解了 Private Connection 表单里 **Host address** 字段的作用。直到用户扔过来一篇 AWS 官方 blog（"Securely connect AWS DevOps Agent to private services in your VPCs"）里的这一段：

> When you create a private connection, the host address you provide is the DNS name that **VPC Lattice resolves to route traffic** to your target. This DNS name **must be publicly resolvable**, even if it resolves to private IP addresses.
>
> When you register a service integration and specify an endpoint URL, that URL is used for the **Host header and Server Name Indicator (SNI)** on the TLS connection, **it is not used for DNS resolution**.

两个 hostname 字段扮演**完全不同的角色**：

| 字段位置 | 作用 | 对 DNS 的要求 |
|---|---|---|
| Private Connection 的 **Host address** | 给 Lattice 做 **DNS 解析**找目标 IP | **必须公网可查**（就算最终解析到私有 IP） |
| MCP Server 的 **Endpoint URL** | 塞进 **Host header + TLS SNI** | 完全不做 DNS 解析，可以是私网 zone 里的名字 |

我之前把 Host address 填成了 `aws-cn.yingchu.cloud` —— 这个名字在 Route53 **私有 zone** 里才能解析，公网查是 NXDOMAIN。Lattice 从公网 DNS 查不到，整条请求根本发不出去。

### 修复

Host address 填 **ALB 的 AWS 托管 DNS 名**：

```
internal-k8s-mcp-mcp-6334395754-126597647.us-east-1.elb.amazonaws.com
```

用 `dig @8.8.8.8 internal-k8s-mcp-mcp-*...` 在公网查，**返回的是私有 IP**（`10.42.23.199` 等）—— AWS ELB 的 DNS 策略就是这么设计的，给的是私有 IP，但 DNS 名本身在公网可查。

```
$ dig +short @8.8.8.8 internal-k8s-mcp-mcp-6334395754-126597647.us-east-1.elb.amazonaws.com
10.42.23.199
10.42.7.200
```

之后 Register MCP Server 时 Endpoint URL 填什么都行（`aws-cn.yingchu.cloud` 作为 Host header / SNI，ALB 靠它做 host-based routing）。

### 关键推论：**一条 Private Connection 能服务多个 MCP**

因为 Private Connection 的 Host address 是同一个 ALB DNS 名，只有 Endpoint URL 不同（决定 Host header / SNI），所以**同一条 Private Connection 可以被多个 MCP Server 注册复用**。你要服务 10 个 MCP Server，只需要一条 Private Connection —— 只要它们都挂在同一个 ALB 后面。

### 教训

**文档上标 optional 的字段未必真的 optional，写明 "required if ..." 的情况千万别忽略**。

更一般的教训：看到 hostname / DNS / URL 同时出现，先问一句 —— **谁来解析？从哪解析？**  别假设一个域名到处都能用。在 AWS 跨越控制平面和数据平面的架构里，"公网可解析"和"VPC 内可解析"是两件事。

---

## 坑 6：MCP 返回 `"Session not found"` —— 多副本踩到的 stateful 陷阱

### 症状

架构全通了，DevOps Agent 能调用 MCP 了，但返回：

```json
{
  "jsonrpc": "2.0",
  "id": "server-error",
  "error": {
    "code": -32600,
    "message": "Session not found"
  }
}
```

`-32600` 是 JSON-RPC 的 `Invalid Request` 错误码。"Session not found" —— 这是从 MCP Server 本身返回的，不是 AWS 层报错了。

### 根因

MCP Streamable HTTP 协议默认运行在 **stateful session** 模式：

1. Client 发 `initialize` → Server 创建 session，返回 `Mcp-Session-Id` header
2. 后续请求 client 带着这个 session ID
3. Server 根据 session ID 维护对话上下文

我部署了 **2 个副本** 追求 HA。ALB 默认 round-robin，结果：

- 请求 1 `initialize` → 路由到 Pod A → 创建 session `abc`
- 请求 2 `tools/list` with session `abc` → 路由到 Pod B → **Pod B 不知道 session `abc` 是谁** → 报错

session state 分裂在两个副本上，互相不共享。

### 修复（3 种思路）

**思路 1：缩到 1 副本**（最快，放弃 HA）

```bash
kubectl -n mcp scale deploy/aws-cn --replicas=1
kubectl -n mcp scale deploy/aws-global --replicas=1
```

所有请求都到同一个 pod，session 不分裂。我现在用的是这个方案。

**思路 2：ALB sticky session**（理论可行但实践不行）

ALB target group 支持 `stickiness.lb_cookie`：ALB 给 client 发一个 cookie，client 在后续请求中带回这个 cookie，ALB 就能把请求锁定到同一个 target。

问题：**MCP Streamable HTTP 的 session ID 在 HTTP header `Mcp-Session-Id` 里，不在 cookie 里**。ALB 不支持 header-based stickiness。而且 DevOps Agent 作为 MCP client 不发 cookie。此路不通。

**思路 3：MCP Server 跑 stateless 模式**（正解，未落地）

FastMCP 框架支持 `stateless_http=True` —— 每个请求自带完整上下文，服务器不维护任何跨请求状态。`awslabs.aws-api-mcp-server` 目前没把这个开关暴露出来，需要 fork 改一行代码或等官方支持。

### 教训

**HA 和 session 天然冲突**。做有状态服务的多副本部署，session 存储要么 externalize（Redis / DynamoDB），要么选 stateless 协议，要么接受 sticky 的代价（但 header-based 没法用 ALB）。

小规模 / demo 场景，1 副本 + K8s 自愈（pod 崩了 controller 会拉新的，有 ~10 秒 downtime）比"跑 2 副本但请求会随机失败"靠谱得多。

---

## 坑 7：Register ≠ Available —— Agent 完全没用我的 MCP

### 症状

所有注册都通了，Agent Space 聊天里输入 `List EC2 instances in cn-northwest-1`，返回：

```
1 tool used: use_aws
Input: { "service_name": "ec2", "operation_name": "describe_instances", "aws_region": "cn-northwest-1" }
Output: { "034362076319": "API call failed: ... AuthFailure ..." }
```

看起来"成功了"，但仔细看两个异常信号：

1. **工具名是 `use_aws`** —— 这是 DevOps Agent 内置的通用 AWS 工具，**不是**我自定义的 MCP
2. **错误信息里的账户 ID `034362076319`** —— 这是我控制台登录态的**全球区账户**，不是我在 MCP 配置的 `AWS_CN_AK/SK` 对应账户

最铁的证据：`kubectl logs deploy/aws-cn --tail=50` 里除了 ALB 健康检查的 `GET /mcp 406`，**一条 `POST /mcp` 都没有** —— 说明我的 pod 根本没收到过业务请求。

### 根因

DevOps Agent 的 MCP 是**两级配置**：

1. **Capability Providers → MCP Server → Register** —— 账户级"上架"，告诉 DevOps Agent 服务你的账户里有这个 MCP 可用
2. **Agent Space → Capabilities → MCP Servers → Add** —— agent 级"启用"，告诉**这个具体的 agent** 可以用哪些 MCP

我只做了第 1 步。第 2 步没做，Agent Space 根本不知道我的 MCP 存在，LLM 只能 fallback 到内置 `use_aws`。

### 修复

Agent Space → 选你的 agent → Capabilities → MCP Servers → Add → 勾选 `aws-cn-mcp` + `aws-global-mcp` → Allow all tools → Save。

保存后重新发一样的问题，工具名应该变成 `aws-cn-mcp___<tool-name>` 类似的带前缀形式，`kubectl logs` 里也会立刻刷出 `POST /mcp 200`。

### 教训

**Register + Associate 是 AWS 常见的两步走设计模式**（SES 域名验证→发信、IAM user→policy、S3 bucket policy→role trust —— 一类思路）。这种设计让 N:M 关系可以显式建模，但对初学者就是多一步容易漏。

看到任何 AWS "注册/创建" 动作，下一步默认问：**"这个东西要怎么关联给使用者？"** 一般都不止一步。

---

## 总结

一条"本该直接工作"的链路，踩了 7 个大坑：

| # | 层级 | 坑 | 修复方式 |
|---|---|---|---|
| 1 | MCP 协议 | supergateway stateless crash | 直接用 aws-api-mcp-server 原生 streamable-http |
| 2 | 构建 | Docker Hub DNS 污染 | 换 `public.ecr.aws/docker/library/*` |
| 3 | 构建 | pip 依赖冲突 | 一个 MCP 一个镜像 |
| 4 | ALB | 健康检查期望 2xx | `success-codes: "200,404,406"` |
| 5 | Lattice | Host address 字段必须公网可查 | 填 ALB 的 AWS DNS 名，不填自定义私有域名 |
| 6 | MCP 协议 | 多副本 + stateful session | 缩到 1 副本 或 stateless 模式 |
| 7 | DevOps Agent | Register 不等于 Add 到 Agent Space | 两级都要配 |

贯穿始终的几个更高层的感悟：

- **每一层抽象都是一层故障面**。supergateway、中间件、协议桥 —— 每个都可能是 bug 来源。Native 优于 adapted。
- **看到 hostname / URL 出现的地方，先问"谁解析，从哪解析"**。跨越控制平面和数据平面时，公网 vs 私网、DNS 解析 vs Host header vs TLS SNI 是三件完全不同的事情。
- **文档标 "optional" 不一定真 optional**。"Required if ..." 的情况一定要看清楚。
- **HA 和 session 天然冲突**。状态要么 externalize，要么用 stateless 协议，要么接受单副本的代价。
- **AWS 很多动作是 Register + Associate 两步走**。看到 "创建成功" 别急着走，问一句"这个资源怎么关联给使用者？"

链路通了之后，后面的路很好走 —— 真 production 化的优化（stateless、HA、私有 subnet + NAT、OAuth 鉴权）都是渐进的。最难的是第一次打通。

---

## 附录：技术参考

- 官方 blog：[Securely connect AWS DevOps Agent to private services in your VPCs](https://aws.amazon.com/blogs/devops/securely-connect-aws-devops-agent-to-private-services-in-your-vpcs/) —— 如果开始做之前读了这篇，能省 3 个坑
- MCP 协议：[Model Context Protocol spec](https://modelcontextprotocol.io)
- FastMCP：[gofastmcp.com](https://gofastmcp.com) —— Python MCP Server 主流框架
- 完整配置参考：本仓库 [SETUP.md](./SETUP.md)
