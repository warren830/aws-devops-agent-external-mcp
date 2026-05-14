# C1 现场演示脚本（明天用）

## 目标

在听众面前**现场跑一次 webhook 自主调查 + 按 agent 给的 mitigation 修复**，
不依赖任何提前录制的截图。耗时约 12-15 分钟。

## 准备一台带 4 个标签页的浏览器

| 标签页 | URL | 用途 |
|---|---|---|
| 1 | DevOps Agent Operator Web App → Agent Space `test-external` → Backlog tasks | agent 调查实时画面 |
| 2 | Slack workspace `AWS` → channel `#test-devops-agent-ychchen` (`C0B39LP1TPZ`) | agent 自主投递通知 |
| 3 | CloudWatch console（cn-north-1, profile ychchen-bjs1）→ Alarms → `bjs-web-pod-not-ready` | 告警状态翻转 |
| 4 | 终端，已 `unset AWS_PROFILE AWS_REGION`，目录 `aws-devops-agent-external-mcp/` | 跑命令 |

## 5 步演示

### 步骤 1（T+0, 30 秒）— 介绍场景 + 注入故障

**讲解**：
> 这是中国区一个真实运行的 EKS 集群 bjs-web，上面跑着 todo-api 三个 pod。
> 一会儿我会模拟开发同学手抖把镜像 tag 写错的场景。

**敲命令**：

```bash
unset AWS_PROFILE AWS_REGION
cd ~/warren_ws/aws-devops-agent-external-mcp/demo-cases/faults
FAULT_AUTO_YES=1 ./inject-L6-pod-imagepullbackoff.sh
```

**预期**：脚本输出最后一行 `L6 injected. New pods will fail with ImagePullBackOff in ~30-60s.`

### 步骤 2（T+30s ~ T+2min, 1.5 分钟）— 等告警 + 看 alarm 翻转

**讲解**：
> CloudWatch 在跑一个 pod 健康检查告警，
> 我们看一下它会不会自动从 OK 翻到 ALARM。

**敲命令**：

```bash
kubectl --context bjs1 -n bjs-web get pods
```

**指给听众看**：第 4 个 pod 状态是 `ImagePullBackOff`。

**切换到 CloudWatch 标签页**，刷新告警页面。等告警颜色从绿（确定）→ 红（告警中）。

**讲解**：
> 这个告警的 action 是把消息推到一个 SNS topic，
> 由 SNS 触发一个 bridge Lambda（处理跨 partition 转发，
> 因为 DevOps Agent 不支持 cn-* partition）。

### 步骤 3（T+2min ~ T+3min, 1 分钟）— Slack 自动通知

**切换到 Slack 标签页**，等几秒，会出现一条新消息：

```
AWS DevOps Agent - US East (N. Virginia)
Investigation started: <bjs-web-pod-not-ready>
I've begun investigating an issue that requires attention.
```

**讲解**：
> 这就是 6C 框架里的协作（Collaboration）+ 便利性（Convenience）：
> 凌晨 3 点告警来了，on-call 工程师还没醒，agent 已经接手开始查。

### 步骤 4（T+3min ~ T+10min, 7 分钟）— 看 agent 自主调查

**切换到 Operator Web App 标签页**，找到 `bjs-web-pod-not-ready` 任务，点进去。

**等 agent 一步步跑** — 它会展示 timeline。

**讲解（动态边看边讲）**：
> 它在调 kubectl describe pod，
> 现在在拉 deployment history，
> 看到了那个 image tag 写错。
> ……
> 调查完成，给出 root cause 和 4 阶段 mitigation plan。

**到 RCA 报告页**，把 root cause 文字念给听众听。

**到 Mitigation plan 页**，展示 4 阶段命令清单。

### 步骤 5（T+10min ~ T+13min, 3 分钟）— 按 mitigation 命令修复

**两条路径任选**：

#### 路径 A — 手敲 agent 给的命令（最透明）

切回终端：

```bash
# Pre-validate（agent 第一阶段）
kubectl --context bjs1 -n bjs-web get deployment todo-api \
    -o jsonpath='{.spec.template.spec.containers[0].image}'
# 应输出当前坏的 image tag v1.2.4-DOES-NOT-EXIST

kubectl --context bjs1 -n bjs-web rollout history deployment/todo-api
# 看历史版本

# Apply（agent 第二阶段）— 走 rollout undo
kubectl --context bjs1 -n bjs-web rollout undo deployment/todo-api

# 或者明确 set image:
# kubectl --context bjs1 -n bjs-web set image deployment/todo-api \
#     todo-api=107422471498.dkr.ecr.cn-north-1.amazonaws.com.cn/bjs-todo-api:v1.2.3

# Post-validate（agent 第三阶段）
kubectl --context bjs1 -n bjs-web rollout status deployment/todo-api
kubectl --context bjs1 -n bjs-web get pods
```

#### 路径 B — 在 console 点 agent 的 "approve" 按钮

如果 mitigation plan 页有 `approve & run` 这种按钮，
直接点，agent 通过它的 MCP 自己执行。
**最体现 approval contract**，但要求 console 支持。

**讲解**：
> 注意 agent 没有自动执行 — 是我们点 approve 它才动。
> 这就是 approval contract：
> agent 给方案 + 具体命令 + rollback 方案 + 等用户审核。
> 任何会改 prod 状态的命令都不会"偷偷"执行。

**最后**：

```bash
kubectl --context bjs1 -n bjs-web get pods
```

3 个新 pod 全部 Running，**incident 关闭**。回到 CloudWatch 看 alarm 又翻回 OK。

---

## 退路（演示翻车时的备用方案）

| 翻车 | 备用 |
|---|---|
| Container Insights metric 没回来 | 提前 24 小时跑一次 inject + recover 让它学会 |
| Slack 通知没到 | 直接展示 Operator Web App 那边的 incident list 截图 |
| Agent 调查太久（> 10 min） | 切到展示之前的 case-1-02-investigation-timeline.png |
| network 抖动 console 进不去 | 切到 7 张已存的截图依次讲解 |

## 提前要做的预热（演示前 30 分钟）

```bash
# 0. 确认两个账号凭证有效
unset AWS_PROFILE AWS_REGION
aws --profile ychchen-bjs1 sts get-caller-identity
aws --profile ychchen-china sts get-caller-identity

# 1. 确认 EKS 健康
kubectl --context bjs1 -n bjs-web get pods

# 2. 确认 Container Insights addon 还活着
kubectl --context bjs1 -n amazon-cloudwatch get pods

# 3. 确认 alarm 在 OK 状态
aws --profile ychchen-bjs1 cloudwatch describe-alarms \
    --alarm-names bjs-web-pod-not-ready \
    --query 'MetricAlarms[0].StateValue' --output text
# 期望: OK

# 4. 浏览器 4 个 tab 都登录好

# 5. 终端 cd 到正确目录 + unset 环境变量
```

## 演示结束后清场

```bash
# 万一 alarm 还在 ALARM，再 recover 一次幂等
cd ~/warren_ws/aws-devops-agent-external-mcp/demo-cases/faults
./recover-L6-pod-imagepullbackoff.sh
```
