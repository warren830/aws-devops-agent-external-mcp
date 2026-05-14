# Agent 怎么访问中国区 EKS — 证据归档

**目的**：把所有调查证据集中起来，回答"DevOps Agent 究竟通过什么路径访问到中国区 EKS 资源"。

**结论先行**：基于 main agent journal 的证据，我**只能确认 2 次 MCP 调用是 CloudWatch Alarm 查询**，**没有直接证据** agent 真的访问了 cn-north-1 EKS API。所谓 "EKS pod 信息" 是 agent **派给 sub-agent 的任务描述**，sub-agent 内部的实际工具调用不在 main agent journal 里。

---

## 证据 1 — Main agent 自己的工具调用清单（journal `c2-journal-real.json`）

**整个调查只调用了 3 个 main-level 工具**：

```
T+0    file_read("understanding-agent-space SKILL.md")    ← 读拓扑文档
T+0    file_read("china-region-multi-account-routing SKILL.md")  ← 读路由文档
T+0    aws_cn_2_mcp_call_aws("aws cloudwatch describe-alarms ...")  ← MCP call #1
T+0    aws_cn_2_mcp_call_aws("aws cloudwatch describe-alarms ...")  ← MCP call #2
T+1m   task_create({task_id: "alb-metrics", ...})        ← 派 sub-agent
T+1m   task_create({task_id: "eks-pod-status", ...})     ← 派 sub-agent
T+1m   task_create({task_id: "rds-metrics", ...})        ← 派 sub-agent
T+1m   task_create({task_id: "cloudtrail-changes", ...}) ← 派 sub-agent
T+1m   task_create({task_id: "pod-logs", ...})           ← 派 sub-agent
T+1m   wait_for_tasks  ← 等 sub-agent 全跑完
T+5m   create_hypothesis * 4
T+6m   create_cause * 3
T+6m   create_observation * N
T+8m   investigation_summary  ← 写最终报告
```

**真正打了 AWS 中国区 API 的只有 2 次**，都是 `aws_cn_2_mcp_call_aws`，调用的是 CloudWatch DescribeAlarms。

## 证据 2 — Main agent 在调查计划里写的"使用 use_kubectl"

派给 `eks-pod-status` sub-agent 的任务描述（main agent 自己写的字符串）：

```
"操作：
1. 使用 use_kubectl 连接 EKS 集群 `bjs-web`（aws_account_id=107422471498, aws_region=cn-north-1）
2. 获取 bjs-web namespace 下所有 pod 的状态（kubectl get pods -n bjs-web -o wide）
3. 描述 todo-api deployment（kubectl describe deployment -n bjs-web）
4. 查看 pod 资源使用情况（kubectl top pods -n bjs-web）
..."
```

**这是 agent "希望" sub-agent 做的事，不是证明 sub-agent 真这么做了。**

## 证据 3 — Sub-agent 完成回执 + 实际返回数据

```
T+1m51s  Background task "alb-metrics" started
T+1m51s  Background task "eks-pod-status" started
T+1m51s  Background task "cloudtrail-changes" started
T+1m51s  Background task "rds-metrics" started
T+1m51s  Background task "pod-logs" started
...
T+3m13s  rds-metrics completed
T+3m50s  cloudtrail-changes completed
T+4m45s  alb-metrics completed
T+5m19s  eks-pod-status completed
T+6m25s  pod-logs completed
```

每个 sub-agent 的 `tool_result` 在 main agent journal 里**全部是 `[]` 空数组或 `ok` 字符串**——没有任何 sub-agent 内部的具体执行细节回到 main agent。

## 证据 4 — Sub-agent 用了什么资源（间接推断）

journal 末尾的 utilization 报告说：

```json
{
  "subagents": [
    {"id": "alb-metrics", "utilization": 2.0},
    {"id": "eks-pod-status", "utilization": 0.3},
    {"id": "rds-metrics", "utilization": 0.3},
    {"id": "cloudtrail-changes", "utilization": 0.3},
    {"id": "pod-logs", "utilization": 1.0}
  ],
  "tools": [
    {"name": "aws_cn_2_mcp_call_aws", "tool_use_count": 2, "utilization": 1.2}
  ]
}
```

**注意**：tools 列表只有 `aws_cn_2_mcp_call_aws` —— **没有 `use_kubectl` 这个工具的使用记录**。
但 sub-agent 有自己独立的 context window 和工具集——utilization 报告只统计 main agent 看到的东西。

## 证据 5 — RCA 报告里写了 EKS 细节

最终 RCA 报告里出现的 EKS 细节：

> "kubernetes-admin 在 05:19:19Z 创建了 c2-load-gen Pod，配置 120 个并发 worker"
> "EKS 集群中当前仅观察到 c2-load-gen 和 todo-api pod"
> "Pod 启动时间与 ALB p99 延迟突变时间点精确吻合"
> "RDS 实例 bjs-todo-db（db.t3.micro，单 AZ）在 05:05 连接数从 3 突增至 30"

这些信息**只可能来自**：
- (A) 真的跑了 `kubectl get pods` / `kubectl describe pod` —— 但 journal 里没有这次调用
- (B) 真的跑了 `aws eks describe-cluster` + 类似 API —— 没记录
- (C) 真的跑了 `aws rds describe-db-instances` + RDS metrics 查询 —— 没记录
- (D) **agent 拿到了 us-east-1 主账号下 GuardDuty / Config / 学到的 topology snapshot 缓存** —— 不太可能，因为 cn 资源不在 us-east-1 主账号视野
- (E) **sub-agent 真的调了上述 API，但 journal 没暴露**（最可能）

## 证据 6 — Agent 自己解释了一遍

agent 在 thinking 里写：

> "The China accounts aren't directly in the enabled associations;
>  instead they're accessed through the custom MCP servers,
>  so I'll need to use the aws_cn_2_mcp tools to reach the Beijing account."

> 中国区账号没有直接加入 enabled associations；
> 它们是通过自定义 MCP server 访问的，
> 所以我需要使用 `aws_cn_2_mcp` 工具来访问北京账号。

**这是直接证据**：agent 自己承认中国区只能走 MCP。

那 sub-agent 内部的 `use_kubectl` 是什么？最可能的解释：
- **sub-agent 的 `use_kubectl` 工具底层就是封装的 `aws_cn_2_mcp_call_aws`**
- sub-agent 调用 `use_kubectl(cluster=bjs-web)` 时，工具实现内部转成 `aws_cn_2_mcp_call_aws("aws eks update-kubeconfig...")` + 后续 kubectl 命令
- main agent 看不到这层封装，所以 utilization 只显示了 main agent 自己的 2 次调用

## 我能确认 vs 我不能确认

### ✅ 100% 可证

1. main agent 调了 `aws_cn_2_mcp_call_aws` 2 次，都是查 CloudWatch alarm
2. agent 自己说"中国区资源只能通过 custom MCP server 访问"
3. main agent 派出 5 个 sub-agent (alb-metrics / eks-pod-status / rds-metrics / cloudtrail-changes / pod-logs)
4. RCA 报告引用了真实的 EKS / RDS 细节（pod 创建时间精确到秒、RDS 连接数变化）

### ❌ 无法独立证明

1. sub-agent 用什么工具拿到了那些 EKS/RDS 细节
2. `use_kubectl` 是不是真的存在为一个独立工具
3. sub-agent 是不是绕过 MCP 直接拿了什么"原生" cn EKS 凭证（不太可能但 main agent journal 不能反证）

## 怎么独立验证（如果想给 PPT 拍铁证）

**方法 A — 看 sub-agent 的 journal**：CLI 暂未暴露这个 API（试过 `list-journal-records` 只支持 main execution-id）

**方法 B — 看 MCP 服务端日志**：去 us-east-1 EKS 跑的 MCP server 看 access log，
应该会看到 sub-agent 真的调了 `aws_cn_2_mcp_call_aws("aws eks ...")` 
和 `aws_cn_2_mcp_call_aws("kubectl ...")` 之类的命令。
这是最干净的铁证 —— 能反证 "sub-agent 也只能走 MCP" 这个论点。

**方法 B 操作命令**：

```bash
unset AWS_PROFILE AWS_REGION

# 1. 看 us-east-1 EKS 上 MCP pod 的日志
kubectl --context <us-east-1 EKS context> -n mcp logs deployment/aws-cn-2 \
    --since=20m | grep -E 'eks|kubectl|describe|pod'
```

如果看到 `aws eks describe-cluster --name bjs-web` 之类的调用，
就证实 sub-agent 也是走 MCP 进来的。

**方法 C — 直接问 agent**：在 chat 里问

> "刚才你调查 bjs-web-p99-latency-high 这个 incident 时，
>  你的 eks-pod-status sub-agent 是怎么连上 EKS 集群 bjs-web 的？
>  它用了哪个工具？"

agent 应该能解释 use_kubectl 的实现路径。

## PPT 的诚实叙事

不要说"5 个 native sub-agent 全 0% 哑火，靠 MCP 顶替"——这个不准确。

可以说：

> ✅ "原生 DevOps Agent 不直接信任中国区 partition 凭证 ——
>     agent 自己 thinking 里写：'China accounts aren't directly in
>     the enabled associations.'"
>
> ✅ "整个 RCA 中，main agent 直接调用的 MCP 工具是 `aws_cn_2_mcp_call_aws` —
>     这个名字本身就证明 agent 把它当成代理访问中国区的统一入口。"
>
> ✅ "5 个 sub-agent 派下去查 ALB/EKS/RDS/CloudTrail/Pod logs，
>     最终 agent 拿到了精确到秒的 cn-north-1 资源信息 —
>     这条访问链可能完全走 MCP，但 main journal 不暴露 sub-agent 内部细节。
>     需要去 MCP server 端看 access log 来确认。"
>
> ✅ "项目部署的 MCP bridge 至少承担了 main agent 直接 AWS API 访问的 100%。"

不要超出证据说话。
