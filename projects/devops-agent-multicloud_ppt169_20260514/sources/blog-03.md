# AWS DevOps Agent 接入 AWS 中国区（三）：8 个 Skill 让 Agent 真正懂你的多账号场景

> MCP 接上了，agent 可以调中国区 API 了 —— 但发一句"中国区有什么问题"，它有 2 个账号可选，也不知道你期望什么格式的输出，也不知道"跨账号 diff"跟"单账号查询"是两件事。Skills 就是填这个空的。本文讲 8 个 skill 的设计思路、实战截图、坑，以及**哪些 skill 设计得好，哪些设计得还不够好**。

*前置：[01-single-account-bridge.md](01-single-account-bridge.md) + [02-multi-account-extension.md](02-multi-account-extension.md) — 如果 MCP 还没接通，先看本系列前两篇。*

---

## 目录

- [1. 问题：MCP 给了能力，没给策略](#1-问题mcp-给了能力没给策略)
- [2. Skills ≠ AGENTS.md — 先澄清概念](#2-skills--agentsmd--先澄清概念)
- [3. 8 个 Skill 的三层架构](#3-8-个-skill-的三层架构)
- [4. 坑 1：YAML frontmatter `: ` 害我重传一次](#4-坑-1yaml-frontmatter---害我重传一次)
- [5. 坑 2：Agent Type 分错了 picker 不选你](#5-坑-2agent-type-分错了-picker-不选你)
- [6. 实战 A：分析层（3 个 use case）](#6-实战-a分析层3-个-use-case)
- [7. 实战 B：生命周期层（Incident Pipeline 全流程）](#7-实战-b生命周期层incident-pipeline-全流程)
- [8. description 触发词设计：最重要的一件事](#8-description-触发词设计最重要的一件事)
- [9. 反思：哪几个 skill 设计得好，哪些不够](#9-反思哪几个-skill-设计得好哪些不够)
- [10. 可抄的 8-skill checklist + 未来加什么](#10-可抄的-8-skill-checklist--未来加什么)

---

## 1. 问题：MCP 给了能力，没给策略

你在 Blog 1 的最后验证了一句"对比 aws-cn 和 aws-cn-2 的 VPC CIDR"，agent 并行调了两个 MCP，给出了对比表。看起来很聪明。

但这句话能**跑得这么顺**的原因，是我在 Agent Space 里注册了一个叫 `china-region-multi-account-routing` 的 skill。没有这个 skill，agent 最常见的几种烂行为是：

- 问一句"中国区有几个 EC2" → agent 随便选一个 MCP（aws-cn 或 aws-cn-2），给一半的答案，不声明是哪个账号
- 问"对比两边成本" → agent 串行查，先宁夏 10 秒，再北京 10 秒，不并行
- 问"修一下那个公开的 S3" → agent 直接 `s3api put-public-access-block ...` 执行，不跟你确认

**MCP 给的是能力（tools 可调用），Skills 给的是策略（什么场景调什么、怎么调、调完怎么组织输出、什么时候停下等人 approve）。** 两者缺一不可。

> 这是官方文档没讲清楚的部分：AWS DevOps Agent 的 Skills 不是 "nice to have"，是让 agent **能用** 的必需配置。没 skill 的 agent 回答质量评估大约是 30%，有 skill 的能到 60%+。这是内部 SOP 文档里的实测数据。

---

## 2. Skills ≠ AGENTS.md — 先澄清概念

一开始我以为 AWS DevOps Agent 用的是 AGENTS.md 约定（OpenAI Codex、Claude Code 用的那个 spec）—— **错**。

对比一下：

| 维度 | AGENTS.md | DevOps Agent Skills |
|---|---|---|
| 文件位置 | 项目根目录 `/AGENTS.md` | Agent Space 里上传的 SKILL.md |
| 加载时机 | 每次对话开始时 agent 会 read 这个文件 | picker 根据 query 语义匹配 description，按需加载 |
| 颗粒度 | 1 个文件管所有指令 | 每个 skill 是一个独立文件，按问题域分 |
| 触发方式 | 总是加载 | **只有 description 关键词匹配到才加载** |
| 可以有多个吗 | 严格说只有一个根 AGENTS.md | N 个 skill 独立存在，可组合 |

DevOps Agent 的 Skills 遵循 [agentskills.io](https://agentskills.io) 子集规范。核心结构是一个带 YAML frontmatter 的 SKILL.md：

```yaml
---
name: my-skill-name
description: 描述 agent 什么时候该用这个 skill（这是 picker 匹配的依据）
---

# Skill 正文 — 告诉 agent 具体怎么做
...
```

> 旧版 DevOps Agent 里这玩意叫 "Runbook"，最近改名 Skills。内部老文档里如果看到 Runbook，知道是同一个东西。

---

## 3. 8 个 Skill 的三层架构

直接上图：

```
┌─ 生命周期层 (incident response pipeline, 4 个按顺序串) ────────────┐
│                                                                    │
│   ⚠️ 告警来了              🔍 定位根因             🔧 出修复命令    │
│   china-incident-triage ─▶ china-incident-rca ─▶ china-incident-   │
│        ▲                                          mitigation       │
│        │                                                            │
│   📅 定时巡检 (每天/每周跑一次)                                     │
│   china-account-prevention-checks                                   │
│                                                                    │
└────────────────────────────────────────────────────────────────────┘
                                   │
                                   │ 所有都用
                                   ▼
┌─ 分析层 (3 个独立工具, Generic agent 也能调) ─────────────────────┐
│                                                                  │
│   cross-account-inventory-compare      ← 对比/diff 资源           │
│   cross-account-cost-attribution       ← 成本对比 + FinOps        │
│   cross-account-security-posture-check ← 安全体检                 │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
                                   │
                                   │ 所有都依赖
                                   ▼
┌─ Foundation 层 (1 个基础, 所有其他 skill 隐式依赖) ──────────────┐
│                                                                  │
│   china-region-multi-account-routing                              │
│   (告诉 agent: aws-cn = 宁夏, aws-cn-2 = 北京, 用户说哪个就查哪个)│
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

截图是 Agent Space 里上传完后的列表视图：

![Skills 列表](screenshots/phase1b-01-skills-list.png)

右半边 "Agent space skills" 8 个是我们自己上传的。底下 "Core skills" 里 `Tool use best practices` 和 `understanding-agent-space` 是 DevOps Agent 内置的 —— 不用管。

### 为什么分三层？

**Foundation 层解决"同一件事所有 skill 都要做"的重复**。比如 "aws-cn = 宁夏" 这个映射，inventory-compare / cost / security / prevention / rca / mitigation 6 个 skill 全都要知道。写一次，让其他 skill 隐式依赖，避免 6 份拷贝。

**分析层的 3 个是 Generic agent 调用的工具**。用户在 chat 里问"对比成本" —— 属于 on-demand query，Generic agent type 就能搞定，不涉及 incident。

**生命周期层的 4 个按严格 handoff 串联**：
- `prevention` 跑在 Evaluation agent（定时任务）
- `triage` / `rca` / `mitigation` 按告警 → 分类 → 根因 → 修复流水
- handoff 数据结构明确：triage 出 Triage Card → rca 吃卡出 RCA Report → mitigation 吃 report 按 Pattern Library 选命令

这种显式 handoff 比"让 agent 自己决定怎么 flow"可靠得多。

---

## 4. 坑 1：YAML frontmatter `: ` 害我重传一次

写完 `cross-account-security-posture-check/SKILL.md`，打包上传，Agent Space 弹了个错：

```
未能上传技能：SKILL.md frontmatter validation failed:
Failed to parse SKILL.md frontmatter:
mapping values are not allowed in this context at line 7 column 66
```

定位 line 7 column 66 过去看，我写了：

```yaml
  are "safe", "following best practices", or "have risks". Covers: public S3
                                                          ^col 66: 冒号 + 空格
```

YAML parser 把 `Covers:` 当成嵌套 mapping 的 key 了 —— 因为它就长得像一个 key-value 对。

> YAML 规范：plain scalar（没引号的字符串）里**不能出现 `: ` (colon-space)**，否则会被解析成 key。`:X`（冒号后没空格）OK，`"X: Y"`（加引号）OK，但光着写 `X: Y` 就错。

修复小菜一碟 — 把 "Covers:" 改成 "The audit checks"：

```diff
-  are "safe", "following best practices", or "have risks". Covers: public S3
+  are "safe", "following best practices", or "have risks". The audit checks
+  public S3 buckets,
```

`: ` 消失，重传，成功。

### 更防御的写法：折叠 block scalar

如果你预计 description 里会有很多冒号、括号、复杂标点，用 YAML 的 `>-`（folded block scalar）：

```yaml
description: >-
  Run a security and compliance posture audit... Covers: public S3 buckets,
  IAM users missing MFA, root account API activity, etc.
```

`>-` 的规则是：把多行 **折叠成一行**，删掉尾部换行，**允许任意特殊字符**。比 plain scalar 容错高一个档次。

### 我为什么没用 `>-`？

因为 8 个 skill 里 7 个的 description 根本不需要 —— plain scalar 够用。只有 security 那个我塞了个 "Covers:" 引子才翻车。**默认 plain scalar，除非 description 里必须写 `: `**。折衷点是：读起来更干净，踩坑概率低。

---

## 5. 坑 2：Agent Type 分错了 picker 不选你

DevOps Agent 有 6 种 agent type（内置，不能改）：

| Agent Type | 什么时候跑 | 谁用 |
|---|---|---|
| Generic | 用户在 Operator Web App 里主动发 query | 通用对话 |
| On-demand | 同上，但偏向"长任务" | 生成报告类 |
| Incident Triage | 告警/ticket 刚进来还没定性 | pipeline 入口 |
| Incident RCA | triage 之后要找根因 | 投入最深的 agent |
| Incident Mitigation | RCA 完成后出修复命令 | 最敏感（可能触发写操作）|
| Evaluation | 定时巡检、proactive recommendation | 定时跑 |

**Skill 上传时，UI 会让你选"这个 skill 适用哪几个 agent type"。** 默认是 Generic（全 agent 通用）。

### 为什么不都选 Generic？

省事嘛 —— Generic 意味着所有 agent type 都能加载。但这会带来**两个实际问题**：

**问题 1：context 污染**。Incident Triage agent 跑的时候，上下文窗口有限。如果 `china-incident-mitigation` 也被加载进来，agent 会被"下一步怎么修"的细节干扰，影响它专注于"这次 incident 是什么 class"的首要任务。

**问题 2：picker 语义匹配冲突**。比如用户问"体检一下"，`prevention` 和 `security-posture-check` 的 description 都可能命中。如果两个都标 Generic，picker 可能两个都加载，answer 质量反而下降。让 prevention 只在 Evaluation agent 加载，security-posture-check 只在 Generic/On-demand 加载，冲突就没了。

### 我的映射决定

| Skill | Agent Type | 原因 |
|---|---|---|
| `china-region-multi-account-routing` | **Generic**（共享） | 所有 agent type 都要知道 routing 规则 |
| `cross-account-inventory-compare` | Generic / On-demand | 用户主动问才触发 |
| `cross-account-cost-attribution` | Generic / On-demand | 同上 |
| `cross-account-security-posture-check` | Generic / On-demand | 同上 |
| `china-account-prevention-checks` | **Evaluation**（仅限） | 定时巡检 |
| `china-incident-triage` | **Incident Triage**（仅限） | pipeline 入口 |
| `china-incident-rca` | **Incident RCA**（仅限） | 深度调查 |
| `china-incident-mitigation` | **Incident Mitigation**（仅限） | 修复建议 |

**5–8 号在上传时必须 uncheck Generic**，只选自己对应的 agent type。这样 Generic agent 聊天时就不会浪费 context 加载 incident pipeline 的 skill。

---

## 6. 实战 A：分析层（3 个 use case）

分析层的 3 个 skill 直接用用户 query 触发，不走告警流程。下面是我跑的 3 个真实 demo + 截图。

### 6.1 Demo — 跨账号 VPC 对比

**Query**: "对比 aws-cn 和 aws-cn-2 的 VPC CIDR"

期望激活的 skill：`routing` (foundation) + `inventory-compare` (scenario)

Agent 的响应：

![VPC 对比 - 完整响应](screenshots/phase2-q1-vpc-compare-top.png)

关键观察：

1. **顶部状态栏**：`2 tools · 1 skill used` —— 这是直接证据，agent 并行调了 2 个 tool（就是 2 个 MCP），加载了 1 个 skill（routing 或 inventory-compare，点进去能看到具体是哪个）。

2. **右上角**：
   ```
   [running aws-cn   (1 Hop List Aws)]
   [running aws-cn-2 (1 Hop List Aws)]
   ```
   两个 MCP 被同时调用 —— 这是 routing skill 里"用户没指定账号时，并行查两边"的规则生效的 ground truth。

3. **输出格式**：markdown 对比表 + 详细 per-account 分解 + 差异总结 —— 这跟 `cross-account-inventory-compare` SKILL.md 里写的输出模板一致：
   - "Side-by-side table (preferred for ≤5 columns)"
   - "Grouped sections (preferred for lists)"
   - "Every instance ID, ARN, or resource name you return must be prefixed or suffixed with the account"

4. **CIDR 冲突分析**：agent 发现两个账号默认 VPC 都是 172.31.0.0/16（重叠），主动提示 Peering 可行性 —— 这是 skill 没明确要求的增值分析，但输出结构让 agent 有空间发挥。好的 skill 不会把 agent 卡死。

5. **"skill used" 点进去**：看到激活的是 `china-region-multi-account-routing`。这有意思 —— picker 匹配到的是 routing，inventory-compare 没被激活？原因是 query 里没有 "对比"/"diff" 这种关键词硬性触发 inventory-compare，picker 认为 routing 就能解决（实际也能）。

   **启示**：想确保 inventory-compare 被激活，可以把 description 里的触发词扩到更贴合用户自然说法。我后来在 SKILL.md 里加了 "对比两个账号" / "列两边" / "两个账号有没有同名" 等短语。

### 6.2 Demo — 跨账号成本对比

**Query**: "这个月 aws-cn 和 aws-cn-2 两个中国区账号各花了多少钱，列个对比表"

期望激活的 skill：`routing` + `cost-attribution`

![成本对比响应](screenshots/phase2-q2-cost-compare.png)

关键观察：

1. **顶部 badge**: `5 tools used` —— 比 VPC 查询多（VPC 是 2）。原因：成本查询要调 Cost Explorer（或 Billing），CE 的 API 本身要多次调用才能拿到 MTD + 按服务分解。

2. **表头**: "2026年5月（本月至今）中国区账号花费对比" —— agent 根据 query 自己生成了标题，包含月份。这是 skill 没硬编码的东西。

3. **细节**: aws-cn 花了 ¥6,318.26，aws-cn-2 数据显示 loading（截图时 CE 对北京账号的查询还没回）。

4. **"说明" 章节**: agent 解释了 aws-cn-2 的数据为什么慢 —— Cost Explorer 对新账号有 24h 刷新窗口。这是 skill 里明确要求的"数据可信度标注"。

### 6.3 Demo — 跨账号安全体检

**Query**: "两个中国区账号有没有安全风险" (偏自然语言，没说具体查什么)

期望激活：`routing` + `security-posture-check`

![安全体检响应](screenshots/phase2-q3-security-baseline-clean.png)

这次响应**非常可信** —— agent 没有"找不到问题就敷衍"，反而真的发现了几个现成问题：

1. **IAM 用户 MFA 审计**（section 二）:
   - AdminCYC 用户：**MFA ❌**（高风险）
   - TestExternalGlobalOps 用户：MFA ❌
   - henry-zhang 用户：MFA ❌
   - similar-to-azure-service-account 用户：MFA ❌
   - ychchen/YC 用户：MFA ✅

2. **新发现风险总结**（section 三）:
   - 🔴 **Admin/YC 有 MFA + 但有 access key**（双因素缺一角）
   - 🔴 **s3-mount-bucket-xx 对 AllUsers 公开**（critical，ACL)
   - 🟠 py-pichen-test 的 bucket 权限过宽
   - 🟡 几个 IAM group/role 的权限过大 `AdministratorAccess`

3. **整体评估**（section 四）:
   - aws-cn: **高风险** — 理由是 3 个 critical finding
   - aws-cn-2: **中风险** — 理由是没 critical 但有若干 high

这个输出的结构跟 SKILL.md 里写的完全一致：
- 分 severity 优先级排序（critical → high → medium）
- 按账号分组，每个 finding 明确 attribution
- 结尾给 "推荐优先处理 public S3" 这种 next-action hint
- **Never 自动 remediate** —— 输出是 findings only

**最让我惊喜的地方**：skill 完全没告诉 agent "你该给 aws-cn 评高风险" 或者 "你应该做 IAM 用户枚举"。我只写了 check catalog（9 个分类别检查）和 severity 定义 —— agent 自己理解了"检查 9 个类别 × 2 个账号，按 severity 聚合" 的行动逻辑，这就是好 SOP 的作用。

> 温馨提示：这个截图里暴露的都是我实验账号里的真实 finding，我会在 incident pipeline section 处理掉。在真实环境中别把这种截图 commit 到 public repo。

---

## 7. 实战 B：生命周期层（Incident Pipeline 全流程）

4 个 skill 按 pipeline 串：

```
(定时)                   告警              定性            定位              修复
prevention ──▶ alarm ──▶ triage ──▶ rca ──▶ mitigation
```

### 7.1 Prevention：体检 "哪些会坏"

**Query**: "体检一下两个中国区账号，有什么潜在风险"

期望激活：`prevention` (Evaluation agent type)

Prevention 跟 security-posture-check 的区别很重要：
- **Security-posture-check**：描述**当前状态下**的风险（IAM 无 MFA、public S3 等）—— 已经出问题的
- **Prevention**：预测**未来 30-90 天内可能出问题**（RDS 单 AZ、证书过期、access key 60 天了将强制轮换）—— 还没出问题但会出

两个 skill 故意 overlap 一部分（比如 access key 年龄），但维度不一样 —— security 看"当前已超标"，prevention 看"当前合规但接近边界"。

Prevention 的 check catalog（9 个预测维度）：
- RDS MultiAZ 关闭（AZ 故障时 30 天风险暴露）
- ASG min=desired=max=1（无冗余）
- 服务 quota 用量 > 80%
- EC2 跑的 AMI > 180 天
- IAM access key 60–90 天（预告 90 天强制轮换）
- ACM cert 30 天内过期（**< 14 天升 IMMEDIATE**）
- Lambda runtime deprecated
- EKS NodeGroup 只有单 instance

实战输出（截图没在这次 session 跑，因为这个 agent type 需要触发定时任务）：

```
⚠️ IMMEDIATE (< 14 days)
- aws-cn:    ACM cert `prod.yingchu.cloud` expires in 7 days

⚠️ Within 30 days
- aws-cn-2:  RDS `prod-db` has MultiAZ disabled
- aws-cn:    IAM key for user ci-deployer is 62 days old

⚠️ Within 60-90 days
- aws-cn:    EC2 instances running 220-day-old AMI (amzn2-ami-hvm-2024.03)
```

### 7.2 Triage：告警进来先分类

**Input**（用户粘的 CloudWatch alarm payload）:

```
AlarmName: S3-Public-Access-Detected-aws-cn
AccountId: 284567523170
Resource: s3-mount-bucket-xx
Severity: Critical
Details: Bucket ACL grants AllUsers READ
```

期望激活：`china-incident-triage`

Triage 的任务不是解决问题，是**定性 + handoff**。输出格式是 Triage Card：

```markdown
## Triage Card

**Affected account**: aws-cn (284567523170)
**Incident class**: identity-credentials (data exposure via public bucket)
**Severity estimate**: Critical (confirmed, not inferred)
**Time of first observation**: 2026-05-11 13:45 GMT
**Duplicate check**: No similar alarm fired in the last 24h
**Recommended next step**: Hand off to `china-incident-rca` for root-cause
                          analysis. Mitigation is time-sensitive.
```

这张 card 就是 handoff 协议。下一个 skill（rca）可以直接读它。

### 7.3 RCA：4-axis 并行分析

**Query**（接 triage 的 Triage Card 后）: "帮我分析这个 incident 的根本原因"

期望激活：`china-incident-rca` (Incident RCA agent type)

RCA skill 的核心设计是 **4-axis 并行调查**：

```
Axis 1: CloudTrail timeline (incident_time ± 15 min)
        ─ 查 s3-mount-bucket-xx 的 API 调用记录

Axis 2: Recent deploys (CloudFormation / CodeDeploy / ECR push)
        ─ 24h 内有没有对这个 bucket 相关栈的变更

Axis 3: Metric anomaly (prior-week baseline)
        ─ bucket 流量/请求量有没有异常

Axis 4: Cross-account blast radius ←★ signature
        ─ 同样的 failure pattern 是不是也在 aws-cn-2 出现了？
```

**Axis 4 是整个架构的杀手锏**：单账号 RCA 永远回答不了"是我们这出问题，还是平台出问题"。两个账号横向对比一下就知道 —— 如果 aws-cn-2 没同步发生类似事件，那就是 aws-cn 账号内的原因（配置/人/最近变更）；如果两个都有，那很可能是 AWS 本身或共同依赖的问题。

期望的 RCA Report 输出：

```markdown
## RCA Report

**Root cause hypothesis**: The bucket ACL was modified by a user-run CLI
on 2026-05-09 at 14:22 UTC. Specifically:
  - Principal: arn:aws-cn:iam::284567523170:user/henry-zhang
  - API: s3:PutBucketAcl
  - Arguments: acl=public-read
  - IP: 52.82.xxx.xxx (internal office range)

**Evidence chain**:
  1. CloudTrail (axis 1): single s3:PutBucketAcl event, no rollback since
  2. Deploys (axis 2): no CloudFormation changes to S3 in the window
  3. Metrics (axis 3): bucket request count spiked from 100/day to 12k/day
     starting 2026-05-10 — consistent with scanner / bot discovery of the
     public bucket
  4. Blast radius (axis 4): aws-cn-2 has no public buckets — NOT a
     platform-wide event. The cause is scoped to aws-cn and to one user.

**Confidence**: High (CloudTrail evidence is definitive)

**Recommended next action**: Hand off to `china-incident-mitigation` with
this Report. Priority: immediate (bucket has been public for 2 days and
saw 24k scanner hits).
```

注意最后一行 "Hand off to mitigation" —— 这是 pipeline 协议，rca 不自己修。

### 7.4 Mitigation：approval contract + Pattern Library

**Query**（接 RCA Report 后）: "那要怎么修"

期望激活：`china-incident-mitigation` (Incident Mitigation agent type)

Mitigation 是整个 pipeline 最敏感的一个 —— 会生成**实际运行就会改 production 状态**的 CLI 命令。所以设计时死守 4 个原则：

**原则 1：Pattern Library**（已知 failure pattern 库）

SKILL.md 里内置了 6 个 pattern：
- Pattern A — Credential failure (AuthFailure / ExpiredToken)
- Pattern B — MCP pod crashloop
- Pattern C — ALB target unhealthy
- Pattern D — **Overly-permissive SG / public S3**（这次场景）
- Pattern E — CloudFormation stack stuck
- Pattern F — Secrets Manager secret accidentally deleted

如果 RCA 的 root cause 不在这 6 个 pattern 里，skill 明确写了："不 improvise"，回复 "not in pattern library, recommend manual operator action"。

**原则 2：4-field output 格式**（every mitigation step）

```
### Mitigation step N — <short name>

Command:
  aws <command> --region <region> --profile <account>  \
    <args>

What it does:
  <one sentence describing the state change>

Rollback:
  aws <undo command> --region <region> --profile <account>  \
    <args>

Approval:
  This command will change production state in <account>.
  Reply "approve step N" to execute, "skip N" to move on, or
  "stop" to abort the mitigation.
```

**原则 3：approval contract**

每条命令都要**用户显式输入 "approve step N"** 才执行。含糊词："yes" / "好" / "ok" —— 都被拒。这是故意抗"语义漂移"：agent 在对话里很容易把用户的"嗯"当成授权，而这是 prod 凭证的生死线。

**原则 4：每次只执行一步**

不能"approve 1-5 step" 这种批量授权。每步单独 approve —— 这样用户在任何一步看到异常都可以 "stop" 立即中止。

期望的 mitigation 输出（针对本次 public S3 事件）：

```markdown
Pattern matched: Pattern D — Overly-permissive SG / public S3

### Mitigation step 1 — Remove public ACL on bucket s3-mount-bucket-xx

Command:
  aws s3api put-bucket-acl \
    --bucket s3-mount-bucket-xx \
    --acl private \
    --profile ychchen-china --region cn-northwest-1

What it does:
  Changes the bucket ACL from public-read to private. Immediately blocks
  public access at the ACL layer.

Rollback:
  aws s3api put-bucket-acl \
    --bucket s3-mount-bucket-xx \
    --acl public-read \
    --profile ychchen-china --region cn-northwest-1

Approval:
  This command will change production state in aws-cn. Reply
  "approve step 1" to execute, "skip 1" to move on, or "stop" to abort.

### Mitigation step 2 — Enable Public Access Block (防止再次被改公开)

Command:
  aws s3api put-public-access-block \
    --bucket s3-mount-bucket-xx \
    --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true \
    --profile ychchen-china --region cn-northwest-1

What it does:
  Sets account-level Public Access Block on this bucket. Any future
  attempt to PutBucketAcl with public grants will be rejected.

Rollback:
  aws s3api delete-public-access-block \
    --bucket s3-mount-bucket-xx \
    --profile ychchen-china --region cn-northwest-1

Approval:
  Reply "approve step 2" to execute, "skip 2" to move on, or "stop" to abort.
```

**step 1 和 step 2 之间必须单独 approve** —— 这就是 approval contract 的纪律。

### 7.5 Pipeline 全流程的 context 流转

串起来看：

```
Alarm payload ─▶ [triage]   ─▶ Triage Card
                                 │
Triage Card  ─────────────▶ [rca]      ─▶ RCA Report
                                             │
RCA Report   ──────────────────────▶ [mitigation] ─▶ 每步 4-field + approval
```

每一级都读上一级的输出作为输入。这种 "explicit handoff 数据结构" 比 "agent 自己决定 flow" 可靠 10 倍 —— 因为数据结构（Triage Card / RCA Report）逼 agent 把结论**写成可验证的文字**，而不是藏在 agent 脑袋里。

---

## 8. description 触发词设计：最重要的一件事

Skill 的成败 80% 在 `description`。**正文写得再好，description 不够，picker 就不选你的 skill，正文等于没写。**

### Bad description 示例

```yaml
description: This skill helps compare resources across accounts.
```

为什么烂：
- 太短（~50 字符，远低于 100 字符推荐最小值）
- 没触发词 —— 用户可能说"对比"、"diff"、"区别"、"两个账号"、"cross-account"，**一个都没覆盖**
- 没声明约束 —— agent 不知道什么时候"不该"用这个 skill

### Good description 示例（我们用的）

```yaml
description: Query the same AWS resource type (EC2, RDS, VPC, subnets, security
  groups, S3 buckets, Lambda functions, IAM roles, CloudFormation stacks, etc.)
  across both China region MCPs (aws-cn and aws-cn-2) and present a side-by-side
  comparison. Use this skill when the user asks to compare, diff, list across
  both, or find differences between 两个账号, 两个中国区, aws-cn vs aws-cn-2,
  宁夏和北京. Also use when the user wants to find drift, inconsistencies, or
  matching resources (same name/tag) across the two accounts.
```

为什么好：
- **400+ 字符**，足够丰富
- **触发词覆盖中英文**：compare / diff / list / drift / 对比 / 两个账号 / 宁夏和北京 / aws-cn vs aws-cn-2
- **声明了边界**：对 "对比" / "同名资源" / "不一致" 这种 query 才用，隐含说了"单账号查询"不适用
- **列了具体资源类型**（EC2, RDS, VPC, SG, S3, Lambda, IAM, CFN）—— picker 语义匹配时，用户问"对比 SG"也会命中

### Description 字数约束

AWS DevOps Agent 的 description 必须在 **100–1024 字符**。太短 picker 信号不够，太长又没必要。我的 8 个 skill description 长度分布在 400-800 字符，经验值是 **500–700 最稳**。

### 调优 description 的反馈循环

1. 上传 skill
2. 写一个期望激活它的典型 query，发给 agent
3. 在响应页面看 "skills used"，是否包含你的 skill name
4. 如果不包含 → picker 没选你 → description 触发词不够
5. 加/改触发词，重新上传（DevOps Agent 会覆盖同名 skill）
6. 再发 query 验证

Demo 6.1 里 VPC 查询 activated 的是 `routing` 而不是 `inventory-compare` —— 就是这个反馈循环捕捉到的。改 description 重传后就正常了。

---

## 9. 反思：哪几个 skill 设计得好，哪些不够

### 设计得好的

✅ **`china-incident-mitigation`** — approval contract + Pattern Library + 4-field 输出模板，整套协议很紧。即便 agent 误判 root cause，mitigation 的 4-field 格式也会让用户看到命令 + rollback + approval prompt，不会盲目执行。

✅ **`china-region-multi-account-routing`** — foundation 设计得最干净。只 110 行，但承载了 6 个其他 skill 的隐式依赖。典型的"小投入高杠杆"。

✅ **`china-incident-rca` 的 Axis 4** — 跨账号 blast radius 是整个项目的 signature feature。单账号 RCA 做不到这个。

### 还不够好的

⚠️ **`cross-account-cost-attribution`** — Cost Explorer 的 API 延迟和账号间数据一致性差异没处理好。北京账号新，CE 数据 refresh 慢 —— skill 应该在输出里更显眼地标注 "partial data due to CE refresh window"。目前只是附注一句。

⚠️ **`cross-account-security-posture-check` 的 check catalog 太 static** —— 9 个 check 写死在 skill 里。如果用户想加一个 check（比如 "CloudFront TLS policy 弱"），得重写 skill。更好的设计是 catalog 做成可配置的 refs 文件，让用户加 check 不动 skill 本体。

⚠️ **`china-account-prevention-checks` 和 `security-posture-check` 的 overlap 太多** —— 都看 IAM key 年龄，都看 public S3。边界用文字解释了（"prevention 看未来风险，security 看当前风险"），但实操起来 agent 可能两个都加载，浪费 context。下一版考虑把 IAM 部分抽出来单独做 skill。

### 我没写但应该写的

❌ **`china-account-drift-detection`** — Terraform / CloudFormation state vs actual state drift。不在当前 8 个 skill 里，但应该有。

❌ **`china-account-capacity-planning`** — 基于过去 30 天增长率预测 instance/storage 用量。prevention 维度还不够完整。

❌ **`cross-account-iam-audit`** — 细粒度 IAM 审计，现在被 security-posture-check 揉进去了，其实值得单独成篇。

---

## 10. 可抄的 8-skill checklist + 未来加什么

### 可抄 checklist

如果你想在自己 repo 里复刻这套 skill 架构：

- [ ] 写 **Foundation skill** — "我的账号/region 映射 + routing 规则"（我的对应：`china-region-multi-account-routing`）
- [ ] 写 **3 个分析层 skill** — inventory / cost / security。每个挑一个最常见的用户 query 作为触发词基础
- [ ] 写 **Prevention skill** — 列 5-10 个 "会在 30-90 天后出问题" 的 check，给每个标 severity + 预期时间线
- [ ] 写 **Triage skill** — 定义 Triage Card 的 schema（affected account / class / severity / dup check / next step）
- [ ] 写 **RCA skill** — 至少 3 个 axis（CloudTrail / deploys / metrics），有第 2 个账号的话加 Axis 4 blast radius
- [ ] 写 **Mitigation skill** — Pattern Library（至少 5 个 pattern）+ 4-field 输出 + approval contract
- [ ] **每个 skill 的 description 500-700 字符**，中英混合触发词
- [ ] 上传时 Agent Type 分配：foundation + analytical → Generic / On-demand；pipeline 4 个 → 各自专属 agent type
- [ ] 在 chat 里跑典型 query 验证 "skills used" 激活列表
- [ ] 发现 picker miss，改 description，重传

### 我下一步想加的 skill

- `china-account-drift-detection` — 比较 Terraform state 和真实 AWS state
- `cross-account-iam-audit` — IAM 细粒度独立出来
- `multi-cloud-topology` — 把 AWS 两个账号 + 阿里云 的拓扑当成一张图

### 如果你想贡献

Fork `aws-devops-agent-external-mcp`，在 `skills/` 里加你的 SKILL.md + README，发 PR。我的 8 个 skill 都在 MIT license，随便改随便用。

---

**本文到此。相关阅读**：

- [01-single-account-bridge.md](01-single-account-bridge.md) — Partition 隔离与 MCP 单账号桥接（系列第一篇）
- [02-multi-account-extension.md](02-multi-account-extension.md) — 多账号扩展、跨云接入与凭证轮换（系列第二篇）
- [skills/](../skills/) — 8 个 SKILL.md 全文
- [agentskills.io](https://agentskills.io) — Skills 规范原文
- [AWS DevOps Agent Skills docs](https://docs.aws.amazon.com/devopsagent/latest/userguide/about-aws-devops-agent-devops-agent-skills.html) — AWS 官方文档
