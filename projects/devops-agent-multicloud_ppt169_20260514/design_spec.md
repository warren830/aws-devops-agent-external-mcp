# DevOps Agent Multi-Cloud — Design Spec

> Human-readable design narrative — rationale, audience, style, color choices, content outline. Read once by downstream roles for context.
>
> Machine-readable execution contract: `spec_lock.md`. Executor re-reads `spec_lock.md` before every SVG page. Keep both in sync; on divergence, `spec_lock.md` wins.

## I. Project Information

| Item | Value |
| ---- | ----- |
| **Project Name** | DevOps Agent Multi-Cloud — 中国区跑通 6C 全套能力 |
| **Canvas Format** | PPT 16:9 (1280×720) |
| **Page Count** | 19 |
| **Design Style** | B) General Consulting + Dark Tech |
| **Target Audience** | AWS / SRE 内部技术评审听众 |
| **Use Case** | 内部技术分享 / 项目评审，25-30 分钟 |
| **Created Date** | 2026-05-14 |

---

## II. Canvas Specification

| Property | Value |
| -------- | ----- |
| **Format** | PPT 16:9 |
| **Dimensions** | 1280×720 |
| **viewBox** | `0 0 1280 720` |
| **Margins** | left/right 60px, top 50px, bottom 40px |
| **Content Area** | 1160×630 |

---

## III. Visual Theme

### Theme Style

- **Style**: B) General Consulting + Dark Tech
- **Theme**: Dark theme
- **Tone**: 技术、严谨、数据驱动、夜间投影友好

### Color Scheme

| Role | HEX | Purpose |
| ---- | --- | ------- |
| **Background** | `#0F1419` | 深炭主背景 |
| **Secondary bg** | `#1A2332` | 卡片 / 内容块背景 |
| **Primary** | `#1565C0` | AWS Bright Blue，标题装饰、主要 emphasis |
| **Accent** | `#FF9800` | 关键数字 / Skill 高亮 / 状态标记 |
| **Secondary accent** | `#42A5F5` | 渐变过渡、links |
| **Body text** | `#E8EAED` | 主文字 |
| **Secondary text** | `#9AA0A6` | 注解、caption |
| **Tertiary text** | `#6B7280` | footer、page number |
| **Border/divider** | `#2D3748` | 卡片边、分隔线 |
| **Success** | `#4CAF50` | "通过" / "OK" 标记 |
| **Warning** | `#F44336` | "ALARM" / "失败" 状态 |

### Gradient Scheme

```xml
<linearGradient id="titleGradient" x1="0%" y1="0%" x2="100%" y2="0%">
  <stop offset="0%" stop-color="#1565C0"/>
  <stop offset="100%" stop-color="#42A5F5"/>
</linearGradient>

<radialGradient id="bgDecor" cx="80%" cy="20%" r="60%">
  <stop offset="0%" stop-color="#1565C0" stop-opacity="0.15"/>
  <stop offset="100%" stop-color="#1565C0" stop-opacity="0"/>
</radialGradient>

<linearGradient id="accentGradient" x1="0%" y1="0%" x2="100%" y2="0%">
  <stop offset="0%" stop-color="#FF9800"/>
  <stop offset="100%" stop-color="#FFB74D"/>
</linearGradient>
```

---

## IV. Typography System

### Font Plan

**Typography direction**: 中文为主 + 英文术语 + 大量代码命令；标题用粗黑（SimHei）形成视觉锚点，正文用 Microsoft YaHei，代码用 Consolas 单独区分。

| Role | Chinese | English | Fallback tail |
| ---- | ------- | ------- | ------------- |
| **Title** | `SimHei`, `"Microsoft YaHei"` | `Arial` | `sans-serif` |
| **Body** | `"Microsoft YaHei"`, `"PingFang SC"` | `Arial` | `sans-serif` |
| **Emphasis** | `SimHei` | `Arial` | `sans-serif` |
| **Code** | — | `Consolas`, `"Courier New"` | `monospace` |

**Per-role font stacks**:

- Title: `SimHei, "Microsoft YaHei", Arial, sans-serif`
- Body: `"Microsoft YaHei", "PingFang SC", Arial, sans-serif`
- Emphasis: `SimHei, "Microsoft YaHei", Arial, sans-serif`
- Code: `Consolas, "Courier New", monospace`

### Font Size Hierarchy

**Baseline**: Body font size = **20px** (medium density — 既能写完整 RCA 文字段又留得下截图)

| Purpose | Ratio | Size @ 20px | Weight |
| ------- | ----- | ----------- | ------ |
| Cover title | 3x | 60px | Heavy |
| Chapter / section opener | 2.4x | 48px | Bold |
| Page title | 1.8x | 36px | Bold |
| Hero number | 1.8x | 36px | Bold |
| Subtitle | 1.3x | 26px | SemiBold |
| **Body content** | **1x** | **20px** | Regular |
| Annotation / caption | 0.7x | 14px | Regular |
| Page number / footnote | 0.55x | 11px | Regular |

---

## V. Layout Principles

### Page Structure

- **Header area**: 高 80px（页码 + 章节锚点 + 标题）
- **Content area**: 高 580px
- **Footer area**: 高 40px（项目名 + 章节 + 页码 + AWS DevOps Agent 标识）

### Layout Pattern Library

会用到的组合（不限于）：

| Pattern | Used in |
|---|---|
| Single column centered | 封面、章节扉页 |
| Symmetric split (5:5) | 原生 vs 本项目对比、before/after |
| Asymmetric split (3:7 / 7:3) | 大截图 + 文字解读（case 页主力）|
| Top-bottom split | 截图横长（mcp-server-log）|
| Three-column cards | Skills 三层架构、6C 框架 |
| Center-radiating | MCP bridge 架构图 |
| Full-bleed + floating text | 章节扉页 |
| Hero-number + caption | 关键数据页（"98 次 cn API 调用"）|

### Spacing Specification

**Universal**:

| Element | Value |
|---|---|
| Safe margin | 60px (left/right), 50/40px (top/bottom) |
| Content block gap | 32px |
| Icon-text gap | 12px |

**Card-based**:

| Element | Value |
|---|---|
| Card gap | 24px |
| Card padding | 24px |
| Card border radius | 12px |
| Three-column card width | 360px |

---

## VI. Icon Usage Specification

### Source

- **Library**: `tabler-filled` (deck-wide one library lock)
- **Brand exception**: 不用 simple-icons（无品牌 logo 需求）

### Recommended Icon List

| Purpose | Icon Path | Used in |
|---|---|---|
| 中国区 / 多云 | `tabler-filled/world` | P02, P05, P06 |
| AWS 全球区 | `tabler-filled/cloud` | P02, P05 |
| EKS / 集群 | `tabler-filled/cloud-computing` | P05, P09 |
| 数据库 / DDB / RDS | `tabler-filled/database` | P05, P14 |
| 告警 / Alarm | `tabler-filled/alert-hexagon` | P09, P12, P14 |
| 通过 / Success | `tabler-filled/circle-check` | P03, P07 |
| 失败 / Error | `tabler-filled/circle-x` | P03 |
| Webhook / 事件 | `tabler-filled/bolt` | P09 |
| Bridge / 桥接 | `tabler-filled/building-bridge-2` | P05, P11 |
| 时间 / 时序 | `tabler-filled/clock-hour-1` | P12 |
| 安全 / shield | `tabler-filled/shield-check` | P07 |
| Skills 内核 | `tabler-filled/code-circle` | P07, P08 |
| 调查 / 探查 | `tabler-filled/eye` | P09, P12 |
| Slack / 消息 | `tabler-filled/messages` | P09 |
| 趋势 / Performance | `tabler-filled/trend-up` | P12 |
| Bug / 故障注入 | `tabler-filled/bug` | P09 |
| 6C 锁 / 凭证 | `tabler-filled/lock` | P05 |
| 流程 / Pipeline | `tabler-filled/flag-3` | P10 |
| 用户 / SRE | `tabler-filled/user` | P09 |

> **lookup audit**: 上面所有 path 已在 `templates/icons/tabler-filled/` 通过 `ls | grep` 验证存在。

---

## VII. Visualization Reference List

```
Catalog read: 70 templates / 10 categories

Per-page selection:
  P05 hub_spoke           | summary-quote: "Pick for star topology with central hub and spokes (e.g., infrastructure interconnects, data exchange between center and 4-8 endpoints, network architecture)."
  P07 pyramid_chart       | summary-quote: "Pick for 3-6 stratified hierarchy layers (e.g. Maslow, maturity model)."
  P10 process_flow        | summary-quote: "Pick for 3-8 sequential steps connected by simple arrows."
  P14 sankey_chart        | summary-quote: "Pick for 3-stage flow with magnitude (sources -> nodes -> sinks)."

Runners-up considered:
  layered_architecture | rejected for P05: agent + bridge + cn account 不是上下层，是中心+辐射关系，hub_spoke 更准
  flowchart            | rejected for P10: chevron 化的 6 步事件链，process_flow 更紧凑
  numbered_steps       | rejected for P10: 缺少箭头连接的视觉感
```

| Visualization Type | Reference Template | Used In |
| --- | --- | --- |
| hub_spoke | `templates/charts/hub_spoke.svg` | P05 (MCP Bridge 架构) |
| pyramid_chart | `templates/charts/pyramid_chart.svg` | P07 (Skills 三层架构) |
| process_flow | `templates/charts/process_flow.svg` | P10 (Webhook 自主调查 6 步) |
| sankey_chart | `templates/charts/sankey_chart.svg` | P14 (C3 4 跳追溯链) |

---

## VIII. Image Resource List

> All 17 user-supplied screenshots, in `images/`. **Status: Existing**.
> Image intent uses **side-by-side** by default for case pages (大截图主力 + 文字解读 column）. The screenshots themselves are paramount evidence; cropping not allowed → mark each with `no-crop` in spec_lock.

| Filename | Dimensions | Ratio | Purpose | Type | Status | Generation Description |
| -------- | --------- | ----- | ------- | ---- | ------ | ---------------------- |
| case-1-01-investigation-list.png | 1196×949 | 1.26 | C1 incident 列表 | Diagram | Existing | — |
| case-1-02-investigation-timeline.png | 3284×4889 | 0.67 | C1 调查 timeline | Diagram | Existing | — |
| case-1-03-rca-report.png | 3290×1910 | 1.72 | C1 RCA 报告 | Diagram | Existing | — |
| case-1-04-mitigation-plan.png | 3338×4973 | 0.67 | C1 修复方案 | Diagram | Existing | — |
| case-1-05-slack-thread.png | 1364×801 | 1.70 | C1 Slack 自主投递 | Diagram | Existing | — |
| case-1-06-cloudwatch-alarm.png | 2810×1638 | 1.72 | C1 CloudWatch alarm 跳变 | Diagram | Existing | — |
| case-1-07-eks-pod-failed.png | 869×219 | 3.97 | C1 kubectl ImagePullBackOff | Diagram | Existing | — |
| case-2-01-investigation-list.png | 1042×802 | 1.30 | C2 incident 列表 | Diagram | Existing | — |
| case-2-02-investigation-timeline.png | 3338×5342 | 0.62 | C2 调查 timeline (5 sub-agent) | Diagram | Existing | — |
| case-2-03-rca-time-anchor.png | 1626×789 | 2.06 | C2 时间锚定证据 | Diagram | Existing | — |
| case-2-04-cloudwatch-p99.png | 1415×825 | 1.72 | C2 p99 曲线 OK→ALARM | Diagram | Existing | — |
| case-2-04-rca-full.png | 3338×3981 | 0.84 | C2 RCA 报告完整 | Diagram | Existing | — |
| case-2-05-mcp-server-log.png | 664×365 | 1.82 | C2 MCP 收到 98 次 cn API | Diagram | Existing | — |
| case-3-01-investigation-list.png | 1027×959 | 1.07 | C3 incident 列表 | Diagram | Existing | — |
| case-3-02-investigation-timeline.png | 3338×3422 | 0.98 | C3 调查 timeline (4 跳) | Diagram | Existing | — |
| case-3-03-rca-summary.png | 963×851 | 1.13 | C3 RCA 摘要（3 cause）| Diagram | Existing | — |
| case-3-05-mcp-server-log.png | 959×812 | 1.18 | C3 MCP 14 次 cn API | Diagram | Existing | — |

---

## IX. Content Outline

### Part 1: 开场 + 项目意义

#### Slide 01 - Cover

- **Layout**: Single column centered + radial gradient bg decor
- **Title**: 中国区跑通 AWS DevOps Agent 6C 全套能力
- **Subtitle**: 用 MCP Bridge + Skills 让 native Agent 看见中国区
- **Info**: ychchen · AWS · 2026-05

#### Slide 02 - 问题：原生 Agent 看不见中国区

- **Layout**: Symmetric split (5:5)
- **Title**: 原生 DevOps Agent ≠ 中国区可用
- **Content**:
  - 左：原生能力清单（6C / Webhook / Slack / GitHub / 跨源关联）
  - 右：原生面对中国区的盲区（cn-* partition / IAM / STS / 凭证）
  - 关键句："agent 自己 thinking 里说：'China accounts aren't directly in the enabled associations.'"

#### Slide 03 - 项目意义：第一次让 6C 落到中国区

- **Layout**: Hero number + caption（大数据 + 三个支撑）
- **Title**: 在中国区跑通 6C，公开资料里的第一次
- **Content**:
  - Hero: "98 次 cn API · 全部经 MCP Bridge"（C2 单 incident 数据）
  - 三个支撑: Bridge 架构 / 9 个 Skill / 3 个真实 case 闭环

### Part 2: 多云管理原理

#### Slide 04 - 多云图景：你需要管什么

- **Layout**: Three-column cards
- **Title**: 一个 SRE 团队，三朵云（实际 6 个账号）
- **Content**:
  - AWS 全球区 (us-east-1) — 1 主账号
  - AWS 中国区 (cn-north-1, cn-northwest-1) — 2 账号
  - 阿里云 / GCP（备用，不在本项目演示焦点）

#### Slide 05 - MCP Bridge 架构（Hub-and-Spoke）

- **Layout**: Center-radiating (hub_spoke 改写)
- **Title**: MCP Bridge — 一条路接进所有中国区资源
- **Visualization**: hub_spoke (see VII)
- **Content**:
  - Hub: us-east-1 Agent Space + MCP server pods
  - Spoke 1: aws-cn (cn-north-1, account 107422471498)
  - Spoke 2: aws-cn-2 (cn-northwest-1, account 284567523170)
  - Spoke 3: 阿里云 / GCP（占位）

#### Slide 06 - Bridge 关键事实：Agent 自己的 thinking

- **Layout**: Single column centered + 大字引用 + 注解
- **Title**: Agent 自己说了：China 账号只能走 MCP
- **Content**:
  - 大字 quote: "China accounts aren't directly in the enabled associations; instead they're accessed through the custom MCP servers."
  - 下注: 来源 — agent 内部 thinking 字段（C2 调查 journal 13:24 BJ）

### Part 3: Skills — 让 Agent 真正懂你

#### Slide 07 - Skills 三层架构

- **Layout**: Pyramid-style stratified
- **Title**: 9 个 Skill，分三层
- **Visualization**: pyramid_chart
- **Content**:
  - 顶层 — Foundation: `china-region-multi-account-routing`
  - 中层 — 分析层: inventory-compare / cost-attribution / security-posture-check
  - 中层 — Pipeline: triage / rca / mitigation
  - 底层 — Prevention: prevention-checks (Evaluation agent)
  - 新增 — `cn-partition-arn-routing`（C5 用，agent 易踩 partition 坑）

#### Slide 08 - Skill 做什么 / 不做什么

- **Layout**: Symmetric split (5:5)
- **Title**: Skill ≠ Agent.md，Skill = 选择性激活的策略库
- **Content**:
  - 左 — Skill 能做：注入领域知识、统一 RCA 输出格式、规约 mitigation 4-field、加锁 approval 协议
  - 右 — Skill 不替代什么：不替代 MCP（能力来源）、不替代 fault → alarm 链路、不替代 console 配置

### Part 4: 三个真实 case

#### Slide 09 - C1 Webhook 自主调查（章节扉页）

- **Layout**: Full-bleed + floating text
- **Title**: Case 1 — Webhook 自主调查
- **Subtitle**: alarm 触发后 90 秒，agent 接管全程；人没碰按钮

#### Slide 10 - C1 流程：6 步链 + 时间线

- **Layout**: Top-bottom split — 上 process_flow chart，下 3 张关键截图缩略
- **Title**: 90 秒自主调查 → 12 分钟出 RCA
- **Visualization**: process_flow (6 步)
  - inject L6 → pod ImagePullBackOff
  - alarm OK→ALARM
  - SNS → bridge Lambda → webhook 200 OK
  - agent 接管 → 自主调查
  - RCA 报告 + 4 阶段 mitigation
  - Slack 自主投递

#### Slide 11 - C1 现场证据

- **Layout**: 2x2 grid（4 张截图缩略 + 一句话解读）
- **Title**: 不是手画占位，是真 agent 真截图
- **Content**:
  - case-1-07 + case-1-06: alarm 跳变
  - case-1-02: 调查 timeline（15 步）
  - case-1-03: RCA 报告
  - case-1-05: Slack 自主投递

### Part 5

#### Slide 12 - C2 时间锚定 RCA（章节扉页）

- **Layout**: Full-bleed + floating text
- **Title**: Case 2 — 时间锚定 + 跨源关联
- **Subtitle**: agent 把 ALB metric 跳变锚到 k8s pod 创建事件，**精确到秒**

#### Slide 13 - C2 关键数据 + 截图

- **Layout**: Asymmetric split (4:6) — 左数据卡，右大截图（case-2-04-rca-full）
- **Title**: 13 分钟 → 3 cause + 6+ 观察 + 精确到秒锚定
- **Content** (左):
  - 调查耗时: 9 分 49 秒
  - 主 agent MCP 直调: 2 次
  - 5 个 sub-agent 各自跑（utilization 0.3-2.0%）
  - **锚定**: c2-load-gen Pod 创建 05:19:19Z = ALB p99 突变点

#### Slide 14 - C2 铁证：MCP server log 98 次 cn API

- **Layout**: Top-bottom split — 上 case-2-05-mcp-server-log 终端截图全宽，下文字注解
- **Title**: 100% cn-* AWS API 经 MCP Bridge
- **Content**:
  - 截图：98 次 API 调用清单（cloudwatch get-metric × 36, logs start-query × 20, cloudtrail × 11, eks-describe × 3, ...）
  - 注解：0 次绕过 MCP；agent 自己 thinking 已确认

#### Slide 15 - C3 多跳拓扑 RCA（章节扉页）

- **Layout**: Full-bleed + floating text
- **Title**: Case 3 — 4 跳追溯到根因
- **Subtitle**: DDB throttle → SQS → ECS → CloudTrail → 锁定 manual ModifyTable

#### Slide 16 - C3 4 跳链路 + 截图

- **Layout**: Top-bottom split — 上 sankey/process（4 跳箭头），下 case-3-03-rca-summary
- **Title**: 沿 4 跳依赖链锁定根因
- **Visualization**: sankey_chart (改写为 4-stage)
- **Content** (4 跳):
  1. DDB describe-table → PROVISIONED 5 WCU
  2. SQS get-queue-attributes → 14272 条积压
  3. ECS describe-services → desiredCount=5
  4. CloudTrail lookup-events → manual ModifyTable @ 07:18:17Z
  + 主动检查 application-autoscaling describe-scalable-targets → 没配兜底

#### Slide 17 - C3 真本事：区分 Terraform vs 手动 CLI

- **Layout**: Asymmetric split (6:4) — 左大引用，右 case-3-02-investigation-timeline 缩略
- **Title**: Agent 通过 CloudTrail user-agent 区分两种创建源
- **Content**:
  - 大引用：`"该表最初由 Terraform 以按需模式创建（2026-05-13T15:07:50Z），不存在节流风险...AdminCYC 在 2026-05-14T07:18:17Z 通过 AWS CLI (ClaudeCode-BH) 将...计费模式从 PAY_PER_REQUEST 手动变更为 PROVISIONED 5 WCU"`
  - 这是真生产 SRE 才会主动确认的细节，agent 自动做了

### Part 6: 收尾

#### Slide 18 - 三个 case 对照

- **Layout**: Three-column cards
- **Title**: 三个 case 同一个核心：MCP Bridge 让 cn-* 透明可达
- **Content**:
  - C1: webhook 自主，0 次 MCP main + 5 sub-agent 走 MCP
  - C2: ALB+RDS+EKS+CloudTrail+Logs Insights 5 源关联，98 次 cn API
  - C3: DDB→SQS→ECS→CloudTrail 4 跳，14 次 cn API
  - 总计 110+ 次 cn API 全部 0 次绕过 MCP

#### Slide 19 - 下一步 + 致谢

- **Layout**: Single column centered
- **Title**: 接下来 / 谢谢
- **Content**:
  - 待跑：C4 跨账号 blast radius / C5 skill 救场 / C6-C10
  - 待写：blog 04 + 现场演示 SOP
  - GitHub: warren830/aws-devops-agent-external-mcp
  - 联系: ychchen@amazon.com

---

## X. Speaker Notes Requirements

- **Filename match**: `01_cover.svg` ↔ `notes/01_cover.md`
- **Total duration**: 25-30 分钟，每页 ~1.3-1.6 min
- **Style**: 技术分享，conversational + 数据点支撑
- **Purpose**: inform + 说服评审 (项目意义 + 真实证据)
- **总文件**: `notes/total.md` 用 `# Slide 01 - Cover` 这种 H1 标记每页边界

---

## XI. Technical Constraints Reminder

### SVG Generation Must Follow:

1. viewBox: `0 0 1280 720`
2. Background uses `<rect>`
3. Text wrapping uses `<tspan>` (`<foreignObject>` FORBIDDEN)
4. Transparency uses `fill-opacity` / `stroke-opacity`; `rgba()` FORBIDDEN
5. FORBIDDEN: `mask`, `<style>`, `class`, `foreignObject`
6. FORBIDDEN: `textPath`, `animate*`, `script`
7. Text characters: 写为 raw Unicode；HTML entities `&nbsp;` `&mdash;` etc. FORBIDDEN; XML reserved 用 `&amp;` `&lt;` `&gt;` `&quot;` `&apos;` 转义
8. `marker-start` / `marker-end` only with `<marker>` in `<defs>`, `orient="auto"`, shape ∈ triangle/diamond/circle
9. `clipPath` only on `<image>` elements

### PPT Compatibility Rules:

- `<g opacity="...">` FORBIDDEN; opacity per-element
- Image transparency uses overlay rect
- Inline styles only
- Font stacks all PPT-safe (SimHei / Microsoft YaHei / Arial / Consolas — 所有都预装)
- `image-rendering: pixelated` 用于截图清晰显示

---
