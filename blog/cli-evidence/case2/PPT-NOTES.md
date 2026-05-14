# Case 2 — 时间锚定 RCA（PPT 素材，**已修正**）

> ⚠️ 旧版 PPT-NOTES 里有"5 个 native sub-agent 全 0% 哑火"的叙事，**这个说法不准确**。
> 详细证据归档见 `HOW-AGENT-ACCESSES-CN-EKS.md`。

## 一句话

> AWS DevOps Agent 自主调查中国区一个真实的 p99 延迟 incident，
> **没有人发任何 query**，
> 12 分钟内给出含 3 个根因 + 6+ 观察项的完整 RCA，
> 精确锚定到 **2026-05-14T05:19:19Z**（c2-load-gen Pod 创建时间）这个事件触发点。

## 关键数据点

来自 agent 真实调查 journal `c2-journal-real.json`（12 分钟里 100 条记录）：

```
入口: CloudWatch alarm bjs-web-p99-latency-high (ALARM 在 05:23:53 UTC)
      → bridge Lambda HMAC-sign POST → DevOps Agent webhook 200 OK
      → INVESTIGATION task 自动创建 (taskId: 9092e8f1)

调查耗时: 8 分钟 49 秒（13:23:57 → 13:32:06 BJ）

主 agent 直接调用的工具:
  - aws_cn_2_mcp_call_aws × 2 次（CloudWatch DescribeAlarms）
  - file_read × 2 次（读 skill 文档）
  - task_create × 5 次（派 sub-agent）

派出的 sub-agent:
  - alb-metrics (utilization 2.0%)
  - eks-pod-status (utilization 0.3%)
  - rds-metrics (utilization 0.3%)
  - cloudtrail-changes (utilization 0.3%)
  - pod-logs (utilization 1.0%)

加载的 skill:
  - understanding-agent-space (utilization 2.3%)
  - china-region-multi-account-routing (utilization 0.8%)
```

## Agent 自己说的关键话

agent thinking 里直接写的：

> "The China accounts aren't directly in the enabled associations;
>  instead they're accessed through the custom MCP servers,
>  so I'll need to use the aws_cn_2_mcp tools to reach the Beijing account."

**这句话本身就是 PPT 角注最强的证据 ——**
agent 自己承认中国区资源走的是 custom MCP，
"原生" associations 里没有中国区账号。

## RCA 主要结论（agent 自己写的）

```
Symptom: bjs-web-p99-latency-high 告警触发，
         ALB k8s-bjsweb-todoapi p99 > 0.5s

Cause #1: 合成负载测试流量 (~26K req/min) 超出系统容量 [Root]
          5/14 05:06 起，流量从基线 73 req/min 暴增至 26K
          (~355 倍)。05:19:19 c2-load-gen Pod 被创建。

Cause #2: RDS bjs-todo-db (db.t3.micro) CPU 持续饱和在 100%
          连接数从 3 突增至 30，CPU 99%+。
          db.t3.micro 仅 2 vCPU，无法处理 26K req/min。

Cause #3: c2-load-gen Pod 在 05:19:19 启动 120 并发 worker 触发延迟突变
          Pod 启动时间与 ALB p99 0.33s→0.74s 突变点精确吻合。

Investigation gap (agent 自己标的): 05:06 初始负载来源未明确
```

**最强的"时间锚定"证据**：

> "c2-load-gen Pod 在 **05:19:19Z** 被 kubernetes-admin 创建，
>  该 Pod 启动时间与 ALB p99 延迟从 0.33s 突变至 0.74s 的时间点**精确吻合**。"

agent 把**精确到秒级**的 Pod 创建事件锚定到了 metric 异常点。
这才是 "deploy-to-incident time anchor" 的真实体现，
锚定的对象是 **k8s 创建事件** 而不是 GitHub commit。

## 演示流程（5 张截图够用）

### 页 1 — 注入故障（in-cluster load gen）

```
unset AWS_PROFILE AWS_REGION
ALB=internal-k8s-bjsweb-todoapi-c36eae0a01-108833280.cn-north-1.elb.amazonaws.com.cn
kubectl --context bjs1 -n bjs-web run c2-load-gen \
    --image=...:v1.2.3 \
    --command -- python3 -c "<120 worker urllib loop>"
```

**讲解**：120 并发持续打 `/api/users/search?email=missing-xxx@nope.example.com`，
该端点对 50000 行 `users` 表做 SeqScan（`email` 列没索引）。

### 页 2 — alarm OK→ALARM（`case-2-05-cloudwatch-p99.png` 待截）

CloudWatch 图表：p99 从 ~330ms → ~1.0s。

### 页 3 — incident list 自主出现（`case-2-01-investigation-list.png`）

新 task `bjs-web-p99-latency-high` 状态"运行中"，**人没操作**。

### 页 4 — 调查 timeline（`case-2-02-investigation-timeline.png`）

5 个 sub-agent 并行跑出 ALB metric / RDS CPU / Pod 日志的 timeline。

### 页 5 — RCA 报告

把 agent 自己写的 3 个 cause 念出来。
**重点强调** "05:19:19Z 精确吻合"——
这就是 AWS 官方 demo 里说的"WGU MTTR 77% 缩短"的时间锚定能力的真实体现。

## 项目意义锚点

> **AWS DevOps Agent 不支持中国区 partition (`cn-*`)**。
> agent 在 thinking 里直接说："The China accounts aren't directly in the enabled associations."
>
> 本项目用：
> 1. us-east-1 EKS 上跑 MCP server (`aws-cn-2.yingchu.cloud`)
> 2. cn 账号本地 bridge Lambda 把 SNS alarm 转成 DevOps Agent webhook
> 3. 9 个自定义 skill（含 routing skill 引导 agent 调用对应 MCP）
>
> agent 在调查中**两个"中国区身份"都用了**：
> - 1 个 skill (`china-region-multi-account-routing`, utilization 0.8%)
> - 1 个 MCP tool (`aws_cn_2_mcp_call_aws`, 直接调用 2 次 + 间接通过 sub-agent)
>
> 这是公开资料里**第一次**让 DevOps Agent 在中国区跑通 webhook 自主调查 + 时间锚定 RCA + skill 路由的完整链路。

## 没看到 GitHub commit 关联（坦白）

agent oncall sub-agent 套件里**没有 GitHub sub-agent**。
GitHub repo 关联了，但 incident-driven 调查不会主动激活 GitHub 工具。

要让它查 GitHub 关联代码 commit，需要在 chat 里**显式问**：

> "看一下这个 incident 期间 warren830/aws-devops-agent-external-mcp
>  仓库 demo-cases/app/bjs-todo-api/ 路径下有没有 commit 改了 search 逻辑。"

这是 DevOps Agent 当前实现的 known gap：alarm-driven 调查
不会主动跨域到代码层。

如果要 PPT 演示 "代码到事件的关联"，最干净的方法：
1. 截 incident-driven RCA（agent 自动跑，锚定到 k8s 事件）
2. 然后**用户主动 chat 问** GitHub commit
3. 截 chat 里 agent 跨 GitHub MCP 查 commit 的回答

第二段是项目"完整能力"演示的延伸，不是同一次调查的输出。

## CLI 证据（在 `cli-evidence/case2/`）

| 文件 | 内容 |
|---|---|
| `01-recent-commit.txt` | 仓库最近 commit `fa052ac` |
| `03-alarm-state.json` | p99 alarm 配置（real ALB ARN）|
| `04-alarm-history.json` | alarm OK→ALARM 跳变记录 |
| `05-p99-datapoints.json` | p99 时间序列 0.07s→1.0s |
| `06-bridge-lambda-logs.txt` | bridge POST webhook 200 OK |
| `07-agent-investigation-task.json` | task 元数据 |
| `c2-journal-real.json` | **agent 完整调查 journal 100 条记录（300 KB）**|
| `09-agent-thinking-and-tool-calls.txt` | journal 里 thinking + tool_use 提取 |
| `HOW-AGENT-ACCESSES-CN-EKS.md` | **诚实证据归档** —— 我能/不能证明的清单 |
