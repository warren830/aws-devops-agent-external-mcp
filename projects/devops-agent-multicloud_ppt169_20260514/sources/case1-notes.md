# Case 1 — Webhook 自主调查（PPT 素材）

## 一句话

> 中国区账号 bjs-web 上一个 EKS pod 出现 `ImagePullBackOff`，**人没碰任何按钮**，
> AWS DevOps Agent 在 90 秒内自主接管：从告警 → 调查 → 找到根因 → 给出修复方案 → Slack 通知。
> **这是中国区原生 DevOps Agent 完全做不到的能力**（DevOps Agent 不支持 cn-* partition），
> 本项目用 us-east-1 webhook + 跨 partition bridge Lambda 把它跑通了。

## 演示流程（PPT 6 页或 8 页可用）

### 页 1 — 故障注入（`case-1-07-eks-pod-failed.png`）

终端截图，3 个 todo-api pod Running + 1 个 ImagePullBackOff。**重点是右下角那一行 `ImagePullBackOff` 红字**。

**讲解词**：
> 我们故意把 deployment 的镜像 tag 改成 `v1.2.4-DOES-NOT-EXIST` 来模拟一次"开发同学手抖" 的真实事故。

### 页 2 — CloudWatch 告警 OK → ALARM（`case-1-06-cloudwatch-alarm.png`）

时间序列图，`pod_status_pending` 指标从 0 → 1，告警状态绿→红跳变。

**讲解词**：
> 我提前在 EKS Container Insights 上配了告警，
> 1 分钟内 `pod_status_pending` 大于等于 1 就告警。
> 告警通过 SNS 推到一个 bridge Lambda（处理 cn-* → 全球 partition 的跨域转发），
> 由它把告警转换成 DevOps Agent 的 webhook payload 并 HMAC 签名 POST 出去。

### 页 3 — Slack 自动通知（`case-1-05-slack-thread.png`）

Slack 频道里看到 `Investigation started: <bjs-web-pod-not-ready>`，时间戳 12:17 PM。

**讲解词**：
> Agent 收到 webhook 后，第一件事就是在 Slack 里登记一条 "调查开始"。
> on-call 工程师此时还可能没醒，但 agent 已经启动调查了。
> 这就是 6C 框架里的 **Collaboration（协作）+ Convenience（便利性）**。

### 页 4 — 调查时间线（`case-1-02-investigation-timeline.png`）

整张调查 timeline 视图，agent 跑了 ~15 步，每一步都明确。

**讲解词**：
> 这是 agent 自主跑出来的调查链，**完全无人干预**。
> 它通过 MCP Server（咱们部署在 us-east-1 EKS 上的桥接代理）调用了：
> - `kubectl describe pod` 查 pod 状态
> - 拉 deployment 历史看最近的 image 变更
> - EKS Container Insights 看资源指标
> - 关联到具体的事件 `Event Channel reference: bjs-web-pod-not-ready-2026-05-14T041719477+0000`

### 页 5 — RCA 报告（`case-1-03-rca-report.png`）

根因分析视图。包含：影响、根本原因、主要观察发现。

**讲解词**：
> Agent 给出的根因诊断：
> - **影响**：Deployment `todo-api` 拉取镜像失败 `v1.2.4-DOES-NOT-EXIST`，
>   导致 ImagePullBackOff，pod 处于 ProgressDeadlineExceeded。
> - **根本原因**：Deployment 的 image tag 在 04:09 UTC 被改为不存在的 `v1.2.4-DOES-NOT-EXIST`。
> - **观察证据**：CloudWatch + kubectl 双源对账。
> 整个调查耗时几分钟，比一个值班 SRE 自己排查至少快 5-10 倍。

### 页 6 — Mitigation Plan（`case-1-04-mitigation-plan.png`）

4 阶段（Prepare / Pre-validate / Apply / Post-validate）的具体修复命令。

**讲解词**：
> 修复方案不是"agent 直接动手改 prod"，
> 而是**生成一份带审批阀的 4 阶段方案**：
> 每一步都有 `kubectl get / set image / rollout undo`、
> 期望结果验证、回滚命令。
> 这就是 **approval contract** ——
> agent 把建议拍出来，人审一下点 approve 才执行。

## 数据要点（PPT 角注用）

- 故障注入到告警触发：~90 秒
- 告警到 webhook POST：< 2 秒（bridge Lambda）
- Webhook 到 RCA 完成：约 ~10 分钟（agent 自主跑完 15 步）
- 调查证据点数：~15 个 tool 调用
- 整个流程**人工干预次数：0**

## 引用的 CLI 证据（在 `cli-evidence/case1/`）

- `06-bridge-lambda-logs.txt`：bridge Lambda 日志，
  含 `webhook_post_result status=200` —— 证明 webhook 真的接到了
- `07-agent-investigation-task.json`：agent backlog task 元数据，
  含 `taskType=INVESTIGATION priority=HIGH executionId=...`
- `04-alarm-history.json`：告警状态变迁历史

## 项目意义锚点

> 中国区账号原生 **没有** AWS DevOps Agent —— 因为它运行在 us-east-1 这种全球
> partition，IAM/STS endpoint 都不通中国区。
> 本项目通过：(1) 在 us-east-1 部 MCP Server 转发 cn 区 API 调用，
> (2) 跨账号 SNS-to-Lambda webhook bridge，
> 让 cn-* partition 的真实告警也能驱动 agent 自主调查。
>
> 截止目前公开资料里，这是**第一个把 AWS DevOps Agent 的 6C 招牌能力
> （Webhook 自主调查、跨账号关联、Slack 协作）跑在中国区真实业务上的方案**。
