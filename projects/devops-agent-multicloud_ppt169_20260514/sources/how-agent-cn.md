# Agent 怎么访问中国区 EKS — 证据归档（已验证版）

## 📌 结论（铁证）

**100% 通过 MCP server**。所有 sub-agent 调用 cn-* AWS API 都走 us-east-1 EKS 上部署的 MCP server (`mcp-aws-cn-2` pod)。**没有任何"原生 cn 凭证"或"绕过 MCP 的直连"**。

---

## 证据链

### 1️⃣ Main agent thinking 里自己说的

```
"The China accounts aren't directly in the enabled associations;
 instead they're accessed through the custom MCP servers,
 so I'll need to use the aws_cn_2_mcp tools to reach the Beijing account."
```

— 来源：`c2-journal-real.json` recordId 8e7a143f-4aca-408d-bb31-411c89dda784

### 2️⃣ MCP server pod 接到的实际 AWS API 调用

C2 调查窗口（**05:20-05:35 UTC**）的 MCP server access log（保存在 `10-mcp-server-c2-window-calls.log`）：

**98 条 AWS API 调用** —— 都从 mcp-aws-cn-2 pod 出去到 cn-north-1：

| 调用次数 | API | sub-agent 用途 |
|---:|---|---|
| 36 | `aws cloudwatch get-metric-statistics` | alb-metrics + rds-metrics |
| 20 | `aws logs start-query` | pod-logs（CloudWatch Logs Insights）|
| 19 | `aws logs get-query-results` | pod-logs |
| 11 | `aws cloudtrail lookup-events` | cloudtrail-changes（找 deploy/create 事件）|
|  3 | `aws eks describe-cluster` | eks-pod-status |
|  3 | `aws logs describe-log-groups` | pod-logs metadata |
|  2 | `aws cloudwatch describe-alarms` | main agent 自己 |
|  1 | `aws logs describe-log-streams` | pod-logs |
|  1 | `aws elbv2 describe-target-groups` | alb-metrics |
|  1 | `aws eks list-nodegroups` | eks-pod-status |
|  1 | `aws eks describe-nodegroup` | eks-pod-status |

### 3️⃣ MCP server 日志样本（cn-north-1 region 的关键调用）

```
2026-05-14 05:26:04.536 | call_aws_helper:315 - Attempting to execute AWS CLI command:
                                                aws eks describe-cluster *redacted*
2026-05-14 05:26:04.549 | core.common.helpers:operation_timer - Interpreting operation
                                                eks.describe_cluster for region cn-north-1
2026-05-14 05:26:05.702 | Operation eks.describe_cluster interpreted in 1.15 seconds

2026-05-14 05:26:23.762 | call_aws_helper:315 - Attempting to execute AWS CLI command:
                                                aws cloudtrail lookup-events *redacted*
                              (← 这是 agent 找到 c2-load-gen Pod 创建事件的来源)

2026-05-14 05:26:51.542 | call_aws_helper:315 - Attempting to execute AWS CLI command:
                                                aws logs start-query *redacted*
                              (← 这是 agent 跑 CloudWatch Logs Insights 统计 26K req/min 的来源)
```

### 4️⃣ Pod-logs sub-agent 用 CloudWatch Logs Insights，不是 kubectl

之前 main agent 的任务描述里写"使用 use_kubectl"——但 sub-agent 实际**没调 kubectl**。
它通过 CloudWatch Logs (因为 EKS pod logs 经 fluent-bit/CloudWatch Container Insights 转发了过来) 用 Logs Insights 查询：

- `start-query` 启动查询
- `get-query-results` 拉结果

这就是为什么 agent 能写出 "todo-api 在 05:19 附近延迟突然从 ~175ms 飙升至 ~540ms"
（来自 logs Insights 对 todo-api pod 日志的 ad-hoc SQL 查询）。

### 5️⃣ EKS pod 创建时间精确到秒（05:19:19Z）从哪来

来源：**CloudTrail `CreateEventInvocation` 事件**——
`aws cloudtrail lookup-events` 的返回数据。

这个跨账号 CloudTrail 查询走的是 MCP，
访问的是 `arn:aws-cn:cloudtrail:cn-north-1:107422471498:trail/...`。

### 6️⃣ 5 个 sub-agent 的实际工作分工（推断）

根据 MCP log 的 API 调用模式：

| Sub-agent | 实际用的 API |
|---|---|
| alb-metrics | `cloudwatch get-metric-statistics` (TargetResponseTime / RequestCount / HealthyHostCount) + `elbv2 describe-target-groups` |
| eks-pod-status | `eks describe-cluster` + `eks list-nodegroups` + `eks describe-nodegroup`（**没真的查 kubectl pod list** —— 它通过 CloudTrail 间接知道 pod 创建事件）|
| rds-metrics | `cloudwatch get-metric-statistics` (CPUUtilization / DatabaseConnections / FreeableMemory) |
| cloudtrail-changes | `cloudtrail lookup-events`（11 次窗口扫描）|
| pod-logs | `logs describe-log-groups` + `logs start-query` + `logs get-query-results`（用 Insights，不用 kubectl）|

---

## 这意味着什么

### 项目最强叙事点（PPT 用）

> **AWS DevOps Agent 在 cn-* partition 的"全部"事实数据访问，
> 100% 经过我们部署的 MCP bridge**。
>
> 一次 incident 调查产生 **98 次 AWS API 调用**，
> 全部通过 `mcp-aws-cn-2` 这一个 pod 转发到 cn-north-1。
> 没有任何调用绕过 MCP 走"原生" cn 凭证（因为根本没有原生 cn 凭证）。
>
> Agent 自己的 thinking 直接说：
> "China accounts aren't directly in the enabled associations;
>  instead they're accessed through the custom MCP servers."

### 这个项目的真实价值

不是"补 native sub-agent 0% 哑火的位置"——
是"**让 native sub-agent 在中国区 partition 上正常工作**"，
方法是把 cn-* AWS API 全部经 MCP server 转发：

```
DevOps Agent (us-east-1)
    ↓ aws_cn_2_mcp_call_aws("aws eks ...")
mcp-aws-cn-2 pod (us-east-1 EKS)
    ↓ aws CLI with cn AK/SK in env
arn:aws-cn:eks:cn-north-1 真实 cn API
```

bridge 的关键：
1. MCP server 自己持有 cn AK/SK（中国区独立账号的凭证）
2. agent 看到 MCP 暴露的 `call_aws` 工具就像看到一个"AWS CLI"
3. agent 把 cn-north-1 当成普通 region 操作
4. 5 个 sub-agent 各自用 MCP 跑自己关心的 API

### 一段对照，PPT 角注用

```
                      原生 DevOps Agent      本项目 (MCP bridge)
cn EKS               ❌ 不可达               ✅ 98 次 API 调用
cn CloudWatch        ❌ 不可达               ✅ alarm/metric 完整
cn CloudTrail        ❌ 不可达               ✅ 跨账号事件锚定
cn RDS               ❌ 不可达               ✅ CPU/连接数曲线
cn Pod logs          ❌ 不可达               ✅ Insights 跨账号查询
跨 partition deploy  ❌ 完全空白             ✅ 精确到秒
                                              (05:19:19Z)
```

---

## 证据文件清单

| 文件 | 内容 | 大小 |
|---|---|---:|
| `c2-journal-real.json` | 完整 agent journal (100 records) | 300 KB |
| `09-agent-thinking-and-tool-calls.txt` | journal 提取的 thinking + tool_use | 33 KB |
| `10-mcp-server-c2-window-calls.log` | **MCP server 在 C2 窗口的 196 行日志** | 32 KB |
| `11-mcp-server-24h-full.log` | MCP server 24 小时全日志 | 1.3 MB |
| `HOW-AGENT-ACCESSES-CN-EKS.md` | 本文 | - |
