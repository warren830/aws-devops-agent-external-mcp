# C2 截图清单（你去截）

## 当前状态

- **Load gen 还在跑**（`c2-load-gen` pod，120 workers，最长跑 15 分钟）
- **p99 alarm 已 ALARM**（05:23:53 UTC = 13:23:53 BJ）
- **Agent investigation IN_PROGRESS**：taskId `9092e8f1-94d2-4854-9c90-a572f4287477`
- **time-anchor commit**: `fa052ac` "feat(search): warn-log slow user-search lookups (>100ms)" pushed at 13:05:19 BJ
- **预期 agent 关联**：commit 13:05 → p99 升高 13:13 → alarm 13:23（差 8-18 分钟，agent 应该能找到）

## 关键时间线（北京时间，参考用）

| 时刻 | 事件 |
|---|---|
| 13:05:19 | commit `fa052ac` pushed to GitHub `warren830/aws-devops-agent-external-mcp` |
| 13:13 ~ 13:18 | load gen 启动 + p99 开始上升 |
| 13:21 ~ 13:23 | p99 持续 > 0.5s |
| 13:23:53 | CloudWatch alarm `bjs-web-p99-latency-high` 翻 ALARM |
| 13:23:53 | bridge Lambda POST webhook 200 OK |
| 13:23:57 | DevOps Agent 创建 INVESTIGATION task `9092e8f1` |

## 截图清单

### 1. Operator Web App — incident list 看到 C2 任务

URL：DevOps Agent console → Agent Space `test-external` → Backlog tasks / Investigations

要截：找到这条 → 截全屏

```
Title: bjs-web-p99-latency-high
Status: IN_PROGRESS（如果完了就是 COMPLETED）
TaskId: 9092e8f1-94d2-4854-9c90-a572f4287477
Created: 2026-05-14 05:23:57 UTC = 13:23:57 BJ
```

**保存**：`blog/screenshots/case-2-01-investigation-list.png` 

### 2. 调查 timeline — agent 跑了哪些 tool

点进那个 task 看时间线视图。
**关键看点**：agent 应该会调
- ALB metric (TargetResponseTime p99)
- RDS Performance Insights / slow query log（如果连了）
- GitHub commit history → 找到 13:05 那个 commit
- kubectl logs（slow query 日志条目）

**保存**：`blog/screenshots/case-2-02-investigation-timeline.png`

### 3. **★ 时间锚定证据 ★** — RCA 报告里 commit 引用 + 时间差

最关键的截图。RCA 报告应该明确写出：
- "metric 异常起点 = T"
- "最后一次部署 / commit = T - X 分钟"
- "commit hash: fa052ac... 引用了 main.py 里的 search_users"

如果它真把 commit 时间和异常时间做了关联，截图说明里要把那段话圈出来。

**保存**：`blog/screenshots/case-2-03-rca-time-anchor.png`

### 4. RCA 全文页

完整的 root cause 段落 + 影响 + 证据链

**保存**：`blog/screenshots/case-2-04-rca-full.png`

### 5. CloudWatch p99 latency 图表

URL：CloudWatch console → Alarms → `bjs-web-p99-latency-high` → Graph view

要截：曲线图，看到 p99 从 ~50ms 突变成 ~1000ms，然后 alarm 状态从绿到红

**保存**：`blog/screenshots/case-2-05-cloudwatch-p99.png`

### 6. GitHub 那次 commit 的页面

URL：https://github.com/warren830/aws-devops-agent-external-mcp/commit/fa052ac

要截：commit diff（让人看到改了 search 函数 + 时间戳 13:05）

**保存**：`blog/screenshots/case-2-06-github-commit.png`

### 7. Slack 自动通知

Slack 频道里应该有第二条 "Investigation started: <bjs-web-p99-latency-high>" 通知

**保存**：`blog/screenshots/case-2-07-slack-thread.png`

---

## 我已存的 CLI 证据（在 `cli-evidence/case2/`）

- `01-recent-commit.txt` — git log 显示 fa052ac 是最近改 main.py 的 commit
- `02-commit-fa052ac-detail.txt` — git show 显示 commit 内容
- `03-alarm-state.json` — alarm 配置
- `04-alarm-history.json` — alarm 状态变化
- `05-p99-datapoints.json` — p99 时间序列（看到从 0.07s 跳到 1.0s）
- `06-bridge-lambda-logs.txt` — bridge POST webhook 的日志
- `07-agent-investigation-task.json` — agent 任务元数据

---

## 截完图后告诉我

完成后说一声，我会：
1. 写 C2 PPT-NOTES.md
2. 删 load gen pod（避免一直跑）
3. 进 C3
