# Case 3 — 多跳拓扑 RCA（PPT 素材）

## 一句话

> DynamoDB 写入节流告警在 cn-northwest-1（宁夏账号）触发，
> AWS DevOps Agent **沿 4 跳依赖链**精确锁定到根因 ——
> **不是 DDB 本身，而是 13 分钟前一次手动改 billing mode 的操作**。
> 整个调查 13 分钟，14 次 cn API 调用全部经 MCP bridge。

## 4 跳追溯链（agent 自己跑出来的）

```
告警触发                  → DDB throttle metric 突破阈值
   │
   ▼
跳 1: DynamoDB 表          → describe-table 看到 PROVISIONED 5 WCU
   │                         (按需切到了 5 WCU)
   ▼
跳 2: SQS 队列              → get-queue-attributes 看到 14272 条积压
   │                         (写入压力来源)
   ▼
跳 3: ECS Worker            → describe-services 看到 desiredCount=5
   │                         (扩容才造成压力)
   ▼
跳 4: CloudTrail 事件        → lookup-events 找到 07:18:17Z 的
   │                         ModifyTable (PAY_PER_REQUEST → PROVISIONED)
   ▼
   也找到 07:18:25Z 的 UpdateService (1 → 5)
   │
   ▼
检查保护机制               → describe-scalable-targets 返回空
                            (确认没有 AutoScaling 兜底)
```

## 关键数据点

| 项 | 值 |
|---|---|
| 触发告警 | `dynamodb-etl-state-throttle` (cn-northwest-1) |
| Bridge POST | 200 OK，incident_id `dynamodb-etl-state-throttle-2026-05-14T074545481+0000` |
| 调查耗时 | 13 分钟（07:46 → 07:59 UTC = 15:46 → 15:59 BJ）|
| MCP server | `mcp-aws-cn` pod（cn-northwest-1 endpoint）|
| AWS API 调用 | 14 次，全部经 MCP bridge |
| 拓扑跳数 | 4 跳 + 1 个保护检查 |
| Agent 找到的 root cause | 手动 ModifyTable @ 07:18:17Z（精确定位到 ClaudeCode-BH user-agent）|

## Agent 用了什么 API（来自 MCP server 日志）

```
  7 aws cloudwatch get-metric-statistics    (throttle / consumption metrics)
  2 aws cloudtrail lookup-events            ★ 找到 ModifyTable + UpdateService 事件
  1 aws sqs get-queue-attributes            (跳 2: 队列深度)
  1 aws ecs list-tasks                      (跳 3: task 状态)
  1 aws ecs describe-services               (跳 3: desiredCount)
  1 aws dynamodb describe-table             (跳 1: billing mode)
  1 aws cloudwatch describe-alarms          (告警上下文)
  1 aws application-autoscaling describe-scalable-targets   ★ 主动检查保护机制
```

## Agent 的关键 Finding（中文原文）

```
Cause: ETL Worker 从 1 实例扩展到 5 实例，写入压力增加 5 倍
   AdminCYC 在 2026-05-14T07:18:25Z 将 ETL Worker ECS 服务的
   desiredCount 从 1 提升到 5...

Cause: etl-state 表未配置 DynamoDB Auto Scaling
   ...确认 describe-scalable-targets 返回空结果，无任何保护机制。

Root Cause: 手动将 etl-state 表从按需模式降级为预置 5 WCU
   AdminCYC 在 2026-05-14T07:18:17Z 通过 AWS CLI (ClaudeCode-BH)
   将 etl-state DynamoDB 表的计费模式从 PAY_PER_REQUEST（按需模式，
   无写入节流上限）手动变更为 PROVISIONED 模式，仅设置了 5 WCU 的
   写入容量。CloudTrail 记录显示该表最初由 Terraform 以按需模式
   创建（2026-05-13T15:07:50Z），不存在节流风险。
```

⚡ **agent 甚至能区分 "Terraform 原始创建" vs "手动 CLI 变更" —— 通过 CloudTrail 的 user-agent 字段**

## 跟 C2 的对比

| 维度 | C2 | C3 |
|---|---|---|
| 故障域 | bjs1 (北京) EKS web app | china (宁夏) ECS data pipeline |
| MCP server | `mcp-aws-cn-2` | `mcp-aws-cn` |
| 拓扑跳数 | ALB → DB CPU 饱和（2 跳）+ 多源关联 | DDB → SQS → ECS → CloudTrail（4 跳）|
| 锚定点 | k8s 事件时间（c2-load-gen pod 创建）| CloudTrail manual change 时间 |
| Agent 主动检查项 | 5 个 sub-agent 并行 | 5 个 sub-agent + AutoScaling 保护检查 |

C2 + C3 一起证明 **MCP bridge 在两个独立中国区账号** 都能让 agent 跑通完整的多源 RCA 调查。

## 截图清单

类似 C2，需要：

1. `case-3-01-investigation-list.png` — incident 列表，看到 dynamodb-etl-state-throttle
2. `case-3-02-investigation-timeline.png` — agent 调查时间线（4 跳追溯过程）
3. `case-3-03-rca-summary.png` — RCA 报告（"手动将 etl-state 表从按需模式降级为预置 5 WCU"）
4. `case-3-04-cloudwatch-throttle.png` — DDB throttle 曲线（OK→ALARM 跳变）
5. `case-3-05-mcp-server-log.png` — `mcp-aws-cn` pod 日志，14 次 cn API 调用

URL: DevOps Agent console → Agent Space `test-external` → Backlog tasks
TaskId: `d93e984e-836b-4f46-a761-6bc550979fe5`

## 文件清单（cli-evidence/case3/）

| 文件 | 内容 |
|---|---|
| `01-alarm-state.json` | DDB throttle alarm 配置 |
| `02-alarm-history.json` | OK→ALARM 跳变历史 |
| `03-ddb-table.json` | `etl-state` 表当前状态 |
| `04-throttle-events.json` | WriteThrottleEvents metric 时间序列 |
| `05-consumed-wcu.json` | ConsumedWriteCapacityUnits 曲线 |
| `06-bridge-lambda-logs.txt` | bridge POST webhook 200 OK |
| `07-agent-investigation-task.json` | task 元数据 |
| `08-mcp-server-c3-window-calls.log` | **MCP server 在 C3 窗口的真实 API 调用** |
| `c3-journal-real.json` | agent 完整调查 journal (52 records) |
| `PPT-NOTES.md` | 本文 |
