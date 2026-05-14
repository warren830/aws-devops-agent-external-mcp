# C3 截图清单

## 当前状态

- ✅ Incident 已 COMPLETED：taskId `d93e984e-836b-4f46-a761-6bc550979fe5`
- ✅ MCP server log 已抓
- ✅ Agent journal 已存（52 records, 128 KB）
- ✅ L5 已 recover

## 5 张截图

### 1. case-3-01-investigation-list.png — incident 列表

URL: DevOps Agent console → Agent Space `test-external` → Backlog tasks/Investigations

找这条:
```
Title: dynamodb-etl-state-throttle
Status: 已完成
TaskId: d93e984e-836b-4f46-a761-6bc550979fe5
Created: 2026-05-14 07:46:07 UTC = 15:46:07 BJ
```

### 2. case-3-02-investigation-timeline.png — 4 跳追溯时间线

点进那个 task 看 timeline。
**关键看点**：
- agent 调用 dynamodb describe-table → 看到 PROVISIONED 5 WCU
- 调 sqs get-queue-attributes → 看到 14272 条积压
- 调 ecs describe-services → desiredCount=5
- 调 cloudtrail lookup-events → 找到 ModifyTable + UpdateService

### 3. case-3-03-rca-summary.png — RCA 报告完整

要看到的内容：
- 症状: dynamodb-etl-state-throttle 告警触发
- 中间原因 1: ETL Worker 从 1 扩到 5
- 中间原因 2: 没配 AutoScaling
- **根本原因**: 手动将 etl-state 表降级为 5 WCU @ 07:18:17Z

### 4. case-3-04-cloudwatch-throttle.png — DDB throttle 曲线

CloudWatch console (cn-northwest-1, profile ychchen-china) → Alarms
→ `dynamodb-etl-state-throttle`

要看到 WriteThrottleEvents 曲线 + 告警状态翻转

### 5. case-3-05-mcp-server-log.png — MCP server 收到的 cn API 调用

```bash
unset AWS_PROFILE AWS_REGION
CTX="arn:aws:eks:us-east-1:034362076319:cluster/mcp-test"

# 直接 cat 已生成的格式化文件给观众看
cat /Users/ychchen/warren_ws/aws-devops-agent-external-mcp/blog/cli-evidence/case3/12-screenshot-ready-mcp-summary.txt
```

预期输出：
```
================================================================================
 C3 调查窗口期间 (07:46~08:00 UTC)，mcp-aws-cn pod 接到的 cn API 调用：

  7 aws cloudwatch get-metric-statistics
  2 aws cloudtrail lookup-events           ★ 找到 manual ModifyTable
  1 aws sqs get-queue-attributes            (跳 2)
  1 aws ecs describe-services               (跳 3)
  1 aws ecs list-tasks
  1 aws dynamodb describe-table             (跳 1)
  1 aws cloudwatch describe-alarms
  1 aws application-autoscaling describe-scalable-targets  ★ 主动检查保护

总计 14 次 cn-northwest-1 API 调用，全部经 MCP bridge
================================================================================
```

截这个终端，保存为 `case-3-05-mcp-server-log.png`
