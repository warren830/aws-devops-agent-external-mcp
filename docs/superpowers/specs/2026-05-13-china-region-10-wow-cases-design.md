# 中国区 AWS DevOps Agent 10 Case 设计文档

> **目标**：在 `ychchen-bjs1`（北京 cn-north-1） + `ychchen-china`（宁夏 cn-northwest-1）两个真实账号上，
> 部署一对**异构 demo 应用**（EKS web app + ECS Fargate data service），
> 设计 10 个能展示 **AWS DevOps Agent 原生招牌能力 + 自定义 Skills/MCP 价值** 的端到端 case。
>
> **项目意义锚点**：DevOps Agent **不支持中国区 partition (`cn-*`)**——本项目用 us-east-1 EKS + Private Connection + 自建 MCP 把中国区接入 agent，是目前**唯一能在中国区跑通 6C 全套招牌能力**的方案。
>
> **状态**：Design v1
> **日期**：2026-05-13
> **作者**：YC Chen + Claude (Opus 4.7)

---

## 0. 背景与设计原则

### 0.1 现有项目状态

仓库 `aws-devops-agent-external-mcp` 已经实现：
- us-east-1 EKS 上 2 副本 MCP server（aws-api-mcp-server，stateless mode）
- VPC Lattice Private Connection（私网接入 DevOps Agent）
- 内部 ALB + ACM 公共通配符证书 `*.yingchu.cloud`
- 多账号 Helm chart（每个 AWS 账号一个 release：aws-cn / aws-cn-2）
- 8 个自定义 Skills（1 foundation + 3 分析层 + 4 incident pipeline）

博客已发：01 单账号桥接、02 多账号扩展、03 Skills 实战（**但 incident pipeline 4 个 skill 的截图全是手画占位，不是真实 agent 输出**）

### 0.2 为什么需要这 10 个 Case

现有项目"有架构但缺 demo"。8 个 skill 写了，但只有分析层 3 个（VPC compare / cost compare / security baseline）有真实 agent 截图证据；incident pipeline 4 个 skill 全是脑补范例。

更重要的是：**项目目前展示的复杂度天花板就是 skill 自己写过的剧本**。要真正"撑起项目意义"，需要把 case 做到 **DevOps Agent 原生招牌能力（拓扑映射/Webhook 自主/时间锚定/多源关联/agent-ready spec/学到的 Skill）+ Skills/MCP 价值** 的层次。

### 0.3 v2 设计原则

1. **WOW Factor 优先**：参考 AWS 官方 6C 框架（Context/Control/Convenience/Collaboration/Continuous Learning/Cost Effective），每个 case 至少展示 1 个 6C 维度
2. **原生招牌能力**：60% 的 case 演示原生 agent 的"AWS 官方 demo 用的招牌"——拓扑映射、Webhook 自主调查、跨源时间锚定、agent-ready spec 交接、ops backlog
3. **中国区差异化**：每个 case 隐含或明示一个"为什么这件事在中国区原生 DevOps Agent 做不到，本项目能做到"的事实
4. **故障可逆**：所有故障注入都有显式 rollback 脚本，demo 完一键复原
5. **成本可控**：demo 期 14 天预算 ≤ ¥1200（含 agent 调查计费 ¥430）
6. **真实证据**：每个 case 必须有真实 agent 输出截图，不允许"手画范例"

---

## 1. 基础设施

两个账号部署完全不同的 stack——展示 agent 在异构架构下的处理能力。

### 1.1 ychchen-bjs1（北京 cn-north-1）— EKS Web App Stack

```
                          ┌─────────────────────┐
   Internet ─▶ ALB ──▶ EKS │ todo-api (3 pods)  │ ──▶ RDS PostgreSQL
                          │ Spring Boot         │     (单 AZ ⚠️)
                          │ Pod Image v1.2.3    │
                          └─────────────────────┘
                                    │
                                    ▼
                              S3 uploads bucket
                              (private + KMS)

   ── CloudWatch Alarms（每个 case 对应一个）
   ── Webhook Bridge Lambda（接 alarm → 调 DevOps Agent webhook）
   ── GitHub repo: bjs-todo-api（agent 能看 commit）
   ── CodePipeline（agent 能看部署时间线）
```

**资源清单**：
| 资源 | 规格 | 月成本 |
|---|---|---|
| EKS 集群 `bjs-web` | 1.31，控制面 | ¥260 |
| 节点组 | 1 × t3.medium | ¥75 |
| RDS `bjs-todo-db` | PostgreSQL 16，db.t3.micro，**单 AZ**（故意） | ¥60 |
| ALB | internal-facing | ¥60 |
| S3 `bjs-todo-uploads` | 私有 + KMS | ¥5 |
| CloudWatch Logs | 30 天保留 | ¥10 |
| Webhook Bridge Lambda | 单函数 | ¥1 |

### 1.2 ychchen-china（宁夏 cn-northwest-1）— ECS Fargate Data Service Stack

```
   EventBridge schedule (daily 0:00)
        │
        ▼
   ┌────────────────────┐
   │ trigger Lambda     │ ──▶ SQS queue ──▶ ECS Fargate Service "etl-worker"
   └────────────────────┘                      │
                                               ▼
                                         DynamoDB "etl-state"
                                               │
                                               ▼
                                         RDS MySQL (multi-AZ ✅)
                                               │
                                               ▼
                                         S3 "china-data-output" (公开 ⚠️)

   ── ECS Fargate Service "report-generator" (cron 触发)
   ── CloudWatch Container Insights
   ── 故意配低内存的 ETL task definition (256MB)
```

**资源清单**：
| 资源 | 规格 | 月成本 |
|---|---|---|
| ECS 集群 `china-data` | Fargate（无控制面成本） | 0 |
| Fargate `etl-worker` | 0.25 vCPU / 256MB（故意太小） | ¥30 |
| Fargate `report-generator` | 0.5 vCPU / 1GB，cron 触发 | ¥10 |
| RDS `china-data-db` | MySQL 8，db.t3.micro，multi-AZ | ¥120 |
| Lambda `etl-trigger` | 单函数 | ¥1 |
| SQS `etl-jobs` | 标准队列 | ¥1 |
| DynamoDB `etl-state` | on-demand | ¥5 |
| S3 `china-data-output` + `china-data-input` | **output 公开**（故意） | ¥5 |

### 1.3 故意埋的 7 个雷（驱动 case）

| # | 雷 | 影响范围 | 触发 case |
|---|---|---|---|
| L1 | bjs-todo-db 单 AZ | 韧性 | C6（prevention） |
| L2 | china-data-output 桶公开 + ECS 周末 auto-scale 异常 | 数据泄露 + 成本 | C10（cost anomaly） |
| L3 | bjs1 IAM access key 65 天 | 凭证轮换 | C6（prevention） |
| L4 | bjs1 一个 commit 加未索引 query | 性能回归 | C2 / C7 / C9（多源 RCA + Kiro 闭环） |
| L5 | china etl-worker task 256MB + DynamoDB 5 WCU（OOM + throttle） | 多跳故障 | C3（多跳拓扑） |
| L6 | bjs1 pod image tag 写错触发 ImagePullBackOff | k8s 故障 | C1（Webhook 自主） |
| L7 | bjs1 IAM trust policy ARN partition 错（`arn:aws:` 应为 `arn:aws-cn:`） | 跨 partition 知识 | C5（agent 犯错 + skill 救场） |
| L8 | bjs1 ALB health-check-interval 240s（应该 30s） | 长尾延迟 | C4（blast radius） |
| L9 | bjs1 todo-api pod CPU limit 100m（过低） | CPU throttle | C9（多根因关联） |

### 1.4 一次性创建脚本结构

```
demo-cases/
├── infra/
│   ├── bjs1-web-stack.tf       # 北京账号资源
│   ├── china-data-stack.tf     # 宁夏账号资源
│   ├── webhook-bridge/         # 桥接 Lambda 源码
│   └── github-repo/            # bjs-todo-api 应用源码
├── faults/                     # 故障注入脚本
│   ├── inject-L1-rds-single-az.sh
│   ├── inject-L2-public-s3.sh
│   ├── ...
│   └── recover-all.sh          # 一键恢复所有故障
├── cases/                      # 每个 case 的 query 模板和验证脚本
│   ├── C1-webhook-autonomous.md
│   ├── ...
│   └── C10-cost-anomaly-backlog.md
└── README.md                   # 总执行 runbook
```

---

## 2. 10 个 Case 详细设计

每个 case 的 spec 包含：**目标 / 涉及资源 / 注入步骤 / 期望 query / 期望输出 / 验收标准 / 截图清单 / 6C 映射**

---

### Case 1 — Webhook 自主调查全流程（中国区原生不支持的招牌能力）

**目标**：演示 alarm → 桥接 Lambda → DevOps Agent webhook → 自主调查 → Slack 输出 RCA + mitigation plan，**人完全不发起**。

**涉及资源**（bjs1）：
- EKS pod 故意配 `image: bjs-todo-api:v1.2.4`（不存在的 tag → ImagePullBackOff）
- CloudWatch alarm `bjs-web-pod-not-ready`
- Webhook bridge Lambda（已部署）
- DevOps Agent webhook URL（手动从 console 生成存到 SSM）
- Slack 频道 `#bjs-web-incidents`

**注入步骤**：
```bash
# 1. 改 deployment image tag 到错误的 v1.2.4
kubectl --context bjs1 -n bjs-web set image deployment/todo-api \
  todo-api=bjs-todo-api:v1.2.4

# 2. 等 30s 让 pod 进入 ImagePullBackOff
# 3. CloudWatch alarm bjs-web-pod-not-ready 触发（基于 EKS Container Insights metric）
# 4. 桥接 Lambda 收到 SNS，构造 incident payload，HMAC 签名，POST webhook
```

**期望 agent 行为**：
1. webhook 收到 incident，自动启动 Incident Triage agent
2. Triage agent 出 Triage Card：识别为 "k8s pod startup failure"，移交 RCA
3. RCA agent 通过 MCP 调 `kubectl describe pod` → 看到 ImagePullBackOff
4. RCA 关联 GitHub deploy 时间线：发现 5 分钟前有 `set image` 操作
5. Mitigation 出 4-field 输出：`kubectl rollout undo` + Pattern B 标签
6. **全部输出贴到 Slack 频道**

**验收标准**：
- [ ] Slack 频道收到至少 3 条 agent 消息（triage card / RCA report / mitigation plan）
- [ ] RCA report 含真实 commit hash 或 kubectl 操作时间戳
- [ ] mitigation plan 含 approval contract 提示语
- [ ] 全程从 alarm 触发到 mitigation 输出 ≤ 8 分钟
- [ ] 人未发任何 query

**截图清单**：alarm 状态 / Lambda 调用日志 / Slack 自主投递的 3 条消息 / agent 调查 timeline

**6C 映射**：Collaboration（自主调查）+ Convenience（人不发起）+ Context（拓扑感知 GitHub commit）

**🇨🇳 中国区差异化**：DevOps Agent 不支持 `cn-*` partition，这个 webhook 在中国区原生**不存在**——本项目用 us-east-1 webhook + bridge Lambda 跨 partition 转发，是中国区第一个能跑通自主调查的方案

**成本估算**：alarm 触发 + 8 分钟调查 ≈ ¥35

---

### Case 2 — 时间锚定的部署关联（commit-to-incident 47s 精度）

**目标**：演示 agent 自动把 metric 异常时间戳和 GitHub commit 时间戳做差值，精确到秒级关联。这是 AWS WGU 案例（MTTR 77% reduction）的核心招式。

**涉及资源**（bjs1）：
- bjs-todo-api 仓库（agent 已连 GitHub）
- 一个故意埋的 commit：`feat: add user search by email` —— 加一个 `WHERE email = ?` query 但 `users.email` 没建索引
- CloudWatch alarm `bjs-web-p99-latency-high`（p99 > 500ms）

**注入步骤**：
```bash
# T-30min: git push 这个 commit，CodePipeline 自动部署
# T-0:    部署完成
# T+45s:  开始压一些 search 流量（用 hey）
hey -z 5m -q 50 -m POST -d '{"email":"x@y.com"}' \
  https://bjs-web.yingchu.cloud/api/users/search

# T+3min: p99 alarm 触发
```

**期望 agent query**："为什么过去 10 分钟 bjs-web 延迟飙升？"

**期望 agent 行为**：
1. 调 CloudWatch metric，识别 p99 异常起点 T
2. 调 GitHub Pipeline API，发现 T-3min 有部署
3. **明确写出**："metric 异常 T=2026-05-13T07:23:42Z，最后一次部署完成 T-2m47s=2026-05-13T07:20:55Z，间隔 167s"
4. 拉对应 commit diff，识别 `WHERE email = ?` 新增
5. 调 RDS Performance Insights（通过 MCP），发现 `users.email` 未索引，全表扫描
6. RCA 输出含具体 commit hash / file:line / 修复建议（加 index）

**验收标准**：
- [ ] agent 输出明确写出"间隔 X 秒/分钟"的时间差表达
- [ ] 输出含具体 commit hash 和 file:line 定位
- [ ] 修复建议含 SQL 语句 `CREATE INDEX idx_users_email ON users(email);`

**截图清单**：agent 输出 timeline 视图（部署 vs metric 对照）/ RCA 报告含 commit 引用 / 流量曲线截图

**6C 映射**：Context（拓扑 + 部署时间线）+ Continuous Learning（关联模式）

**🇨🇳 中国区差异化**：CodePipeline 中国区是 ZHY-1 partition，agent 通过 MCP 跨 partition 关联

**成本估算**：~¥50（含部署 + agent 调查 ~10min）

---

### Case 3 — 多跳拓扑漫游 RCA（4 跳依赖链）

**目标**：演示 agent 沿 Lambda → SQS → ECS task → DynamoDB 的 4 跳依赖链定位真正根因（DynamoDB throttle），而不是停在表层（ECS task fail）。

**涉及资源**（china）：
- Lambda `etl-trigger` (cron 0:00 每天)
- SQS queue `etl-jobs`
- ECS Fargate service `etl-worker` (0.25 vCPU / 256MB)
- DynamoDB `etl-state`（故意 provisioned 5 WCU，造业务数据 → 触发 throttle）

**注入步骤**：
```bash
# 1. 把 etl-state 切换到 provisioned billing mode，5 WCU
aws --profile ychchen-china dynamodb update-table \
  --table-name etl-state --billing-mode PROVISIONED \
  --provisioned-throughput ReadCapacityUnits=5,WriteCapacityUnits=5 \
  --region cn-northwest-1

# 2. 手动触发 etl-trigger Lambda（推 100 条到 SQS）
aws lambda invoke --function-name etl-trigger ...

# 3. ECS service 启 5 个 task 并行处理 → throttle
# 4. CloudWatch alarm: ecs-etl-task-failures (rate > 50%)
```

**期望 agent query**："china 账号 ETL 失败了，根因是什么"

**期望 agent 行为**（演示拓扑漫游）：
1. **第 1 跳**：调 ECS GetTasks → tasks 大量 STOPPED, exit code 137
2. **第 2 跳（agent 自主跳到上游）**：查 ECS task 上游是 SQS-driven，调 SQS metric → 队列长度暴涨但消息被消费了
3. **第 3 跳**：task logs 显示 `ProvisionedThroughputExceededException`
4. **第 4 跳**：调 DynamoDB metric → ConsumedWriteCapacity 一直顶在 5 WCU = 配额上限
5. **结论**：根因不是 ECS（那只是症状），是 DynamoDB capacity
6. 输出依赖图（mermaid）+ throttle metric 截图

**验收标准**：
- [ ] agent 输出明确画出 4 跳依赖图（Lambda → SQS → ECS → DynamoDB）
- [ ] 在每一跳都有具体证据（metric 曲线 / log line）
- [ ] 最终结论指向 DynamoDB 而非 ECS
- [ ] 修复建议：切换 on-demand mode 或提高 WCU

**截图清单**：agent 跳转步骤序列截图 / 拓扑视图 / DynamoDB throttle 曲线

**6C 映射**：Context（拓扑智能 - 多跳）

**成本估算**：~¥40

---

### Case 4 — 跨账号 Blast Radius 验证（RCA Axis 4 真实演示）

**目标**：用真实 incident（不是 v1 的"对比 VPC"假演）验证跨账号 blast radius——bjs1 出问题时 agent 自动检查 china 是否同步受影响，做 platform-wide vs account-scoped 判定。

**涉及资源**：
- bjs1 EKS 应用 + ALB
- china ECS 应用（参照对比）
- `china-region-multi-account-routing` skill（已有）
- `china-incident-rca` skill 的 Axis 4（已有）

**注入步骤**：
```bash
# 在 bjs1 注入: ALB 健康检查间隔从 30s 改成 240s（4 分钟）
# 当 pod 不健康时，ALB 4 分钟才把它踢出去 → 长尾延迟
aws --profile ychchen-bjs1 elbv2 modify-target-group \
  --target-group-arn ${BJS1_TG_ARN} \
  --health-check-interval-seconds 240 \
  --region cn-north-1

# 然后干一个 pod
kubectl --context bjs1 -n bjs-web delete pod $(kubectl ... | head -1)

# CloudWatch alarm: alb-5xx-rate-high
```

**期望 agent query**："bjs1 ALB 5xx 升高，是不是 china 账号也出问题了"

**期望 agent 行为**（依赖 routing skill + RCA Axis 4）：
1. 在 bjs1 调 ALB metric / target health → 确认 5xx 来自 healthcheck 长延迟
2. **关键**：自动并行调 china 账号同名 metric（这是 cross-account 真本事）
3. china 账号 ALB metric 完全正常
4. 输出 4-axis RCA report，特别强调："Blast Radius: scoped to bjs1 account only. NOT a platform-wide issue."
5. 修复建议：把 health-check-interval 改回 30s

**验收标准**：
- [ ] agent 同时调用 bjs1 + china 两个 MCP（agent 端能看到 "2 tools used"）
- [ ] RCA report 第 4 节明确 "blast radius" 段落
- [ ] 判定为 account-scoped 而非 platform-wide
- [ ] 修复建议指向具体配置项

**截图清单**：tools panel 显示并发调用 / RCA report Axis 4 截图 / 双账号 metric 对照图

**6C 映射**：Context（跨账号上下文）+ Continuous Learning（rca skill 沉淀）

**🇨🇳 中国区差异化**：原生 DevOps Agent **完全不支持中国区跨账号**（因为根本不支持 `cn-*` partition）。这是项目签名能力。

**成本估算**：~¥30

---

### Case 5 — Agent 犯错 → Custom Skill 救场（Hypothesis Refinement Demo）

**目标**：演示原生 agent 的经典局限——它能找全证据但归错责（参考 AWS Fundamentals Test 3）。然后展示 custom skill 如何编码"中国区 partition 知识"让 agent 改对。这是 **continuous learning** 的最强证明。

**涉及资源**（bjs1）：
- 一个 IAM role 故意写错：trust policy 里 `arn:aws:iam::*:role/...`（应为 `arn:aws-cn:`）
- 一个 Lambda 试图 assume 这个 role → AccessDenied
- CloudWatch alarm

**注入步骤**：
```bash
# 1. 创建 IAM role 时故意用 aws partition ARN（agent 能编辑就编辑，不能就 hardcode）
# 2. Lambda 调用 sts:AssumeRole → AccessDenied，报错
# 3. alarm 触发
```

**期望 agent 行为（第一遍——不加 skill）**：
1. agent 找到 Lambda 报错日志：`User x is not authorized to perform sts:AssumeRole on Y`
2. 找到 IAM role trust policy
3. **agent 误判**：认为是 trust policy 缺权限，建议加 `sts:AssumeRoleWithSAML` 之类
4. 这是错的——真正问题是 partition ARN 写错了

**注入 skill 后第二遍**：
- 上传新 skill `cn-partition-arn-routing`：编码"在 cn-north-1 / cn-northwest-1 区域的 IAM ARN 必须是 `aws-cn` partition，不是 `aws`"的领域知识
- 重新发同一 query
- agent 这次正确识别 partition mismatch，给出修复 ARN

**验收标准**：
- [ ] 第一遍输出（不加 skill）含**错误的修复建议**（明确截图保留）
- [ ] 加 skill 后第二遍**正确识别 partition 问题**
- [ ] 两次输出对照展示在截图里
- [ ] skill 触发记录里能看到 `cn-partition-arn-routing` 被 picker 选中

**截图清单**：错误诊断 / 加 skill 前后对照 / skill activation 记录

**6C 映射**：Continuous Learning（**项目核心论点：skill 让 agent 越来越准**）

**🇨🇳 中国区差异化**：partition ARN 是中国区独有的"agent 经常踩"的领域知识

**成本估算**：~¥40（跑两遍调查）

---

### Case 6 — Predictive Evaluation（Ops Backlog 生成）

**目标**：演示 Evaluation agent type 跑 prevention skill，输出"未来 30/60/90 天会出事的点"，每个 finding 含 business impact 评分。这是 v1 完全没真跑过的能力（v1 是占位输出）。

**涉及资源**：
- 雷 L1（bjs-todo-db 单 AZ）→ 应该被预测为 30 天内风险
- 雷 L3（IAM key 65 天）→ 应该被预测为 25 天内必须轮换（90 天硬限）
- 多个其他真实 finding：ASG 单实例、cert 倒计时、Lambda runtime deprecated 等
- `china-account-prevention-checks` skill（已有，需在 Evaluation agent type 上注册）

**注入步骤**：
```bash
# 不需要"注入"——L1 / L3 已经是基础设施的常驻状态
# 只需要在 Agent Space 启动 weekly evaluation schedule，或手动触发 on-demand evaluation
```

**期望 agent query**（手动触发 evaluation）："执行 weekly prevention check，生成 ops backlog"

**期望 agent 行为**：
1. agent 跑 prevention skill 9 个 check 维度
2. 输出按 severity 分组：
   - 🔴 IMMEDIATE (<14d): 0 个
   - 🟠 30 days: bjs-todo-db single-AZ; IAM key xxx age 65d (rotation in 25d)
   - 🟡 60-90 days: ASG min=desired=1 单点; ACM cert 80 天到期
3. 每个 finding 标 business impact：`high / medium / low`
4. 输出 ops backlog（可执行任务清单），按 priority 排序

**验收标准**：
- [ ] 至少 5 个真实 finding（来自基础设施常驻状态）
- [ ] 每个 finding 标 severity + business impact
- [ ] 输出 markdown ops backlog 格式
- [ ] L1（RDS 单 AZ）和 L3（IAM key 65 天）必须被识别

**截图清单**：Evaluation agent timeline / ops backlog 输出全文 / 截图按 severity 排序的 finding 表

**6C 映射**：Continuous Learning（预防）+ Cost Effective（事前 vs 事后）

**成本估算**：~¥80（evaluation 跑全维度耗时较长）

---

### Case 7 — Agent-ready Spec → Coding Agent 实施（闭环 agentic SRE）

**目标**：演示 RCA → mitigation plan → agent-ready spec → 编码 agent（Kiro 或 Claude Code）执行 → PR 自动提交。这是 AWS 官方主推的"完整 agentic SRE 闭环"。

**涉及资源**：
- C2 的 RCA 输出（用 C2 的 incident 做承接）
- bjs-todo-api GitHub 仓库（已连 agent）
- Claude Code 或 Kiro CLI（用 Claude Code）

**步骤**：
1. 完成 C2，得到 RCA "missing index on users.email"
2. 在 agent 控制台点 "Generate mitigation plan"
3. agent 输出 4 阶段方案（Prepare / Pre-Validate / Apply / Post-Validate）
4. **关键步骤**：点 "Generate agent-ready spec"
5. 把 spec 拷到 Claude Code，让 CC 执行：
   - 在仓库新建 migration `0042_add_users_email_index.sql`
   - 改 `db/migrate.go` 注册 migration
   - 提 PR，PR 描述含 RCA 链接
6. 验证 PR diff 正确

**期望 agent 行为**：
1. agent 输出的 spec 包含：
   - context（指向 RCA）
   - 期望的代码变更（filename + 改什么）
   - 验收标准
   - rollback 步骤
2. 喂给 Claude Code 后 CC 在 5 分钟内提交 PR

**验收标准**：
- [ ] agent-ready spec 文件可以独立给一个不知情的 coding agent 看懂
- [ ] Claude Code 收到 spec 后正确生成 migration
- [ ] PR 自动 push 到 GitHub
- [ ] PR 描述里引用了 incident ID 和 RCA report URL

**截图清单**：spec 全文 / Claude Code 接收并执行的过程 / 最终 PR 截图

**6C 映射**：Collaboration（跨 agent 协作）+ Continuous Learning（机构知识沉淀到 PR）

**🇨🇳 中国区差异化**：原生中国区无 DevOps Agent，无法生成 spec。本项目演示"在中国区 incident 中生成 spec → 让全球 coding agent 接力"

**成本估算**：~¥30（agent spec 生成时间短）

---

### Case 8 — Topology-driven Onboarding Query（新 SRE 入职体验）

**目标**：演示 Convenience（6C #3）。模拟新 SRE 提问"列出连接到 china-data-db DynamoDB 的所有资源"，agent 凭学到的拓扑直接列：上下游资源、IAM 角色、CloudWatch alarms、最近改它的 deploy。无需手工配置任何工具。

**涉及资源**：
- DynamoDB `etl-state`（已部署）
- 上下游：Lambda etl-trigger / SQS etl-jobs / ECS etl-worker / IAM role
- agent space 已学到拓扑（部署后等 24h 让 learned skills 跑完）

**期望 agent query**："列出连接到 etl-state 这张 DynamoDB 表的所有资源，包括上下游服务、IAM 权限、监控告警、最近的部署变更"

**期望 agent 行为**：
1. 不需要查 MCP，凭学到的拓扑直接列出：
   - **直接读写**：ECS service `etl-worker` (via IAM role `etl-task-role`)
   - **间接触发**：Lambda `etl-trigger` → SQS `etl-jobs` → ECS
   - **IAM**：role `etl-task-role`（含 `dynamodb:PutItem` on `etl-state`）
   - **告警**：`dynamodb-throttle-rate`、`dynamodb-consumed-wcu`
   - **最近部署**：3 天前 ECS task definition 升 v8（CodePipeline）
2. 输出拓扑图（mermaid 或 ASCII）
3. **关键**：所有信息都来自 agent 拓扑学习，**不需要 SRE 提供任何 context**

**验收标准**：
- [ ] 列出至少 6 个相关资源
- [ ] 含 IAM permission 路径
- [ ] 含 CloudWatch alarms
- [ ] 含最近部署事件
- [ ] **agent 没问任何"哪个集群？哪个区？"的反问**——纯从学到的拓扑取数

**截图清单**：query 输入 / agent 输出全文 / 拓扑图

**6C 映射**：Convenience（零配置上下文）+ Context（拓扑智能）

**成本估算**：~¥10（纯查询无 RCA）

---

### Case 9 — 5 源多信号 RCA（升级版多源关联）

**目标**：bjs-todo-api 延迟飙升，agent 自动并行查 5 个数据源关联根因。比 v1 的"VPC compare"调用 2 个数据源升级一个数量级。

**涉及资源**（bjs1）：
- CloudWatch metrics
- RDS Performance Insights
- EKS Container Insights (pod resource pressure)
- ALB target health
- GitHub recent commits

**注入步骤**（联合 C2 的 query 注入 + 加 pod resource pressure）：
```bash
# 1. 部署 C2 的未索引 commit
# 2. 同时给 todo-api pod 注入 CPU 限制（resources.limits.cpu: 100m）→ pod throttling
# 3. 再压流量
```

**期望 agent query**："过去 15 分钟 bjs-todo-api 延迟从 50ms 飙到 500ms，到底什么原因，给我一份完整的关联分析"

**期望 agent 行为**：
1. 同时启动 5 路并行调查：
   - (a) CloudWatch latency metric → 异常起点 T
   - (b) RDS slow query log + Performance Insights → 全表扫描
   - (c) EKS pod CPU usage / throttling % → CPU throttle 增加
   - (d) ALB target health → 没问题
   - (e) GitHub commit history → 25 分钟前 push 的 search query commit
2. **agent 关联两个独立根因**：
   - 主根因：未索引 query（影响 70%）
   - 辅根因：pod CPU 限制太低（放大效应）
3. 输出 timeline 视图：5 路调查的时间序合并展示
4. 给两个修复建议，按优先级排序

**验收标准**：
- [ ] agent 调用 ≥4 个不同 MCP / 数据源
- [ ] 输出明确把两个独立根因区分开
- [ ] 修复建议按优先级排序
- [ ] timeline 视图含 5 个数据源

**截图清单**：tools panel（≥4 tools used）/ 完整 timeline / 多根因报告

**6C 映射**：Context（多源拓扑关联）

**成本估算**：~¥60（5 源并行查询时间长）

---

### Case 10 — Cost Anomaly + Ops Backlog（FinOps Closed Loop）

**目标**：演示 agent 周一跑 evaluation 模式发现 china 周末 cost 突增（造数据），关联到 ECS auto-scaling 异常，生成 ops backlog（含 budget alert / capacity 模式切换 / 异常告警 3 个建议）。

**涉及资源**（china）：
- Cost Explorer（数据）
- ECS service auto-scaling 配置（故意配错 → 周末跑了一堆 task）
- Cost Anomaly Detection（可选 native，否则 MCP）
- `cross-account-cost-attribution` skill（已有，需要增强）

**注入步骤**：
```bash
# 周五晚上把 ECS service desired-count 临时改高到 20（模拟 auto-scale 异常）
# 周末实际跑 60+ Fargate task hour
# 周一早 8 点跑 evaluation
```

**期望 agent query**（手动）："本周 china 账号 cost 周末有没有异常，生成 ops backlog"

**期望 agent 行为**：
1. 调 Cost Explorer → 周末日费用比平日高 5x
2. 按 service 拆解 → ECS Fargate 占 80%
3. 调 ECS GetServices → 看到周五晚 18:30 desired-count 从 2 跳到 20
4. 调 CloudTrail → 找到那次 UpdateService 的 principal（演示账号本人触发）
5. 输出 ops backlog（3 个 recommendation）：
   - 建议 1：把 ECS service 加 max-capacity hard cap = 5
   - 建议 2：开 Cost Anomaly Detection 自动报警
   - 建议 3：周末 budget alert 阈值降低 50%

**验收标准**：
- [ ] 准确定位 cost spike 来源到 ECS 而不是其他服务
- [ ] 找到具体 UpdateService 调用的 principal + 时间
- [ ] ops backlog 含 ≥3 个可执行建议
- [ ] 每个建议含 expected savings 估算

**截图清单**：cost explorer 截图 / agent 关联 timeline / ops backlog markdown

**6C 映射**：Continuous Learning（周期性洞察）+ Cost Effective（FinOps 闭环）

**成本估算**：~¥50（CE 多次查询 + RCA 长）

---

## 3. 故事线（如果做成 blog 04 单独成篇）

提议结构：

1. **开场（C1）**：4 分钟自主调查 - 震撼力最强
2. **原生招牌（C2/C3/C9）**：拓扑 + 时间锚定 + 多源关联
3. **中国区差异化（C4/C5）**：跨账号 + custom skill 价值
4. **预防价值（C6/C10）**：Evaluation + ops backlog
5. **闭环（C7）**：交接到 coding agent
6. **Convenience（C8）**：附加 demo

---

## 4. 风险和限制

### 4.1 已知风险

| 风险 | 缓解方案 |
|---|---|
| 凭证过期 | 开始 demo 前先 `aws sso login --profile ychchen-bjs1` 等刷新 |
| Agent 不识别中国区资源 | 走我们已有的 us-east-1 EKS MCP bridge |
| Webhook bridge Lambda 故障 | 部署阶段 dry-run 验证 |
| Cost Explorer 数据延迟 | 至少提前 48h 部署基础设施 |
| 故障注入误伤生产 | 所有故障带显式 rollback 脚本，部署在专用账号 |

### 4.2 验收前置条件

- [ ] 两个账号凭证有效
- [ ] us-east-1 EKS MCP 跑通（已有）
- [ ] DevOps Agent space 可用，含 webhook
- [ ] Slack 频道连通
- [ ] GitHub repo `bjs-todo-api` 创建并已连 agent

### 4.3 demo 完成后清理

```bash
# 一键 teardown
cd demo-cases/infra
terraform destroy -auto-approve
# 手动删 webhook（agent console UI）
# 手动从 agent space 删 GitHub 集成
```

---

## 5. 成本汇总

| 项目 | 14 天预算 |
|---|---|
| bjs1 EKS + RDS + ALB + S3 + Lambda | ¥230 |
| china ECS + RDS + DynamoDB + SQS + S3 | ¥120 |
| CloudWatch logs/metrics | ¥30 |
| Data transfer / NAT | ¥40 |
| **基础设施合计** | **¥420** |
| Agent 调查计费（10 case ≈ 2.5h × ¥217/h） | ¥543 |
| **总计** | **¥963** |

---

## 6. 后续步骤

1. **用户 review 本 spec**（你正在做）
2. 进入 implementation plan（`writing-plans` skill）：把 case 拆成可执行任务
3. **执行计划**：
   - Phase 1：基础设施部署（terraform）
   - Phase 2：故障注入脚本编写
   - Phase 3：每个 case 顺序执行 + 截图
   - Phase 4：（可选）写 blog 04
   - Phase 5：teardown

---

**End of Design Document v1**
