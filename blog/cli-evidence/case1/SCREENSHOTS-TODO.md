# C1 截图清单（你去截）

DevOps Agent 在 us-east-1，Account 034362076319 (`ychchen-demo-hub` profile)。
Agent Space: `test-external` (id: a68c0cba-9a71-46f6-8228-88e8fc733990)

---

## 关键时间点（北京时间）

- **04:09 BJ** — 注入 L6 故障（pod 镜像写错）
- **04:13 BJ** — pod 进入 ImagePullBackOff
- **04:17:34 BJ** — DevOps Agent 收到 webhook，开始自主调查（task `0376a356-8e62-42b8-a767-1ed30a5c80f7`）
- **状态**：调查 IN_PROGRESS

## 1. Operator Web App — Investigations 列表

URL：进入 DevOps Agent console → 选 Agent Space `test-external` → 左边栏 "Investigations" 或 "Backlog tasks"

要截：找到这条 → 截全屏

```
Title: bjs-web-pod-not-ready
Status: IN_PROGRESS（如果完了就是 COMPLETED）
Priority: HIGH
TaskId: 0376a356-8e62-42b8-a767-1ed30a5c80f7
Created: 2026-05-14 04:17:34 UTC = 12:17:34 BJ
Reference: EventChannel-bjs-web-pod-not-ready-2026-05-14T041719477+0000
```
![img.png](case-1-01-investigation-list.png)
**截图保存为**：`blog/screenshots/case-1-01-investigation-list.png`

## 2. 点进 Investigation 看调查时间线 / 步骤

点开那条 task。看到的是 agent 一步步跑的过程：
- 它会调 kubectl describe pod（通过 MCP）
- 看到 ImagePullBackOff
- 关联到最近的 deploy 操作
- 给出 RCA + mitigation 建议

要截：**整条调查的时间线视图**（agent 用了几个 tool、按什么顺序）

**截图保存为**：`blog/screenshots/case-1-02-investigation-timeline.png`

## 3. RCA 报告页

调查完成后会有一个 Root Cause 部分。要截那一页 —— 包括：
- Root cause hypothesis
- Evidence chain（CloudTrail / kubectl / GitHub commit 引用）
- Confidence 评分

**截图保存为**：`blog/screenshots/case-1-03-rca-report.png`

## 4. Mitigation plan 页

下面会有 "Generate mitigation plan" 按钮或自动生成的步骤。截那一页：
- 4-stage 方案（Prepare / Pre-validate / Apply / Post-validate）
- 具体命令（应该是 `kubectl rollout undo` 或类似）

**截图保存为**：`blog/screenshots/case-1-04-mitigation-plan.png`

## 5. Slack 频道里 agent 自动发的消息

Slack workspace `AWS`, channel `C0B39LP1TPZ`（应该是 `#bjs-web-incidents` 或类似）

要截：完整的对话线 —— agent 自主投递的所有消息（开始调查 / 中间更新 / 最终 RCA + mitigation）

**截图保存为**：`blog/screenshots/case-1-05-slack-thread.png`

## 6. CloudWatch alarm 状态变化图

URL：CloudWatch console (cn-north-1, profile ychchen-bjs1) → Alarms → `bjs-web-pod-not-ready`

要截：图表显示 OK → ALARM 跳变（最近 1 小时）

**截图保存为**：`blog/screenshots/case-1-06-cloudwatch-alarm.png`

## 7. EKS pod 状态截图

```bash
unset AWS_PROFILE AWS_REGION
kubectl --context bjs1 -n bjs-web get pods -o wide
```

或者去 EKS console 看 Workloads → bjs-web/todo-api → 看到那个 ImagePullBackOff pod

**截图保存为**：`blog/screenshots/case-1-07-eks-pod-failed.png`

---

## 我已保存的原始证据（在 `cli-evidence/case1/`）

- `01-pod-state.txt` — kubectl get pods 输出
- `02-pod-describe.txt` — kubectl describe pod 输出（含 ImagePullBackOff event）
- `03-alarm-state.json` — alarm 当前状态
- `04-alarm-history.json` — alarm 状态变化历史
- `05-metric-pod-pending.json` — pod_status_pending metric 时间序列
- `06-bridge-lambda-logs.txt` — bridge Lambda 收到 SNS → POST webhook 的日志
- `07-agent-investigation-task.json` — agent backlog task 元数据

---

## 截完图后回来告诉我

完成后说一声，我直接 recover L6 → 进入 C2。

如果 C1 调查还没完成（IN_PROGRESS），可以先截 list 视图、调查中视图、Slack 已发消息；调查完了再补充 RCA + mitigation 页。
