# C2 截图清单 — 简化版（只剩 3 张）

## 已截 ✅

- `case-2-01-investigation-list.png` — incident 列表，C2 task 在里面
- `case-2-02-investigation-timeline.png` — 调查 timeline 视图

## 剩这 3 张

### ★ case-2-03-rca-summary.png — RCA 报告完整页

进入 Operator Web App → Agent Space `test-external` → Backlog tasks
→ 点 `bjs-web-p99-latency-high` task (taskId `9092e8f1-94d2-4854-9c90-a572f4287477`)
→ 找到 **"根本原因" / "调查摘要"** 那个 tab

要看到的内容：
- 症状 (Symptoms): bjs-web-p99-latency-high 告警触发
- 根本原因 (Root cause): "合成负载测试流量 (~26K req/min) 超出系统容量"
- 中间瓶颈 (Cause): "RDS bjs-todo-db CPU 持续饱和在 100%"
- 时间锚定: "kubernetes-admin 在 05:19:19Z 创建了 c2-load-gen Pod...精确吻合"

**保存为**: `blog/screenshots/case-2-03-rca-summary.png`

### ★ case-2-04-cloudwatch-p99.png — p99 曲线 OK→ALARM 跳变

CloudWatch console (cn-north-1, profile ychchen-bjs1)
URL: https://console.amazonaws.cn/cloudwatch/home?region=cn-north-1#alarmsV2:alarm/bjs-web-p99-latency-high

要看到：
- p99 时间序列从 ~330ms 跳升到 ~1.0s
- 告警状态绿色 (OK) → 红色 (ALARM) 跳变
- 时间窗口选 14:00-14:30 BJ（C2 那段）

**保存为**: `blog/screenshots/case-2-04-cloudwatch-p99.png`

### ★ case-2-05-mcp-server-log.png — 终端：MCP server 收到的 cn API 调用

这张是 **本项目最强的"铁证"截图**，是 PPT 项目意义那页的关键素材。

操作：

```bash
unset AWS_PROFILE AWS_REGION
CTX="arn:aws:eks:us-east-1:034362076319:cluster/mcp-test"

# 漂亮的输出格式给观众看
kubectl --context "$CTX" -n mcp logs deployment/mcp-aws-cn-2 --since=24h | \
    awk '/2026-05-14 05:2[0-9]|2026-05-14 05:3[0-5]/' | \
    grep "Attempting to execute AWS CLI command" | \
    sed 's/.*command: //; s/ \*parameters redacted\*.*//' | \
    sort | uniq -c | sort -rn
```

预期输出（已验证）:
```
  36 aws cloudwatch get-metric-statistics
  20 aws logs start-query
  19 aws logs get-query-results
  11 aws cloudtrail lookup-events
   3 aws eks describe-cluster
   3 aws logs describe-log-groups
   2 aws cloudwatch describe-alarms
   1 aws logs describe-log-streams
   1 aws elbv2 describe-target-groups
   1 aws eks list-nodegroups
   1 aws eks describe-nodegroup
```

**截这个终端窗口**（高清放大），保存为 `blog/screenshots/case-2-05-mcp-server-log.png`

讲解词:
> 我们在 us-east-1 EKS 上部署的 MCP server (`mcp-aws-cn-2` pod)，
> 在 9 分钟的 incident 调查窗口里，**真实接到 98 次** AWS API 调用，
> 全部目标是 `arn:aws-cn:` 的中国区资源。
> agent 自己在 thinking 里写："China accounts aren't directly in
> the enabled associations"——它只能通过这条 MCP 路径访问中国区。
> **这就是项目存在的全部意义**。

---

## 截完图后告诉我

这 3 张截完，C2 完整证据链就齐了：截图 + CLI 证据 + journal + MCP server log。
我会直接进 C3 (多跳拓扑 RCA)。
