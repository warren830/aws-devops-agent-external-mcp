# AWS DevOps Agent 对运维人员的 7 个最大价值

> 粘贴到飞书文档时，直接 Ctrl+V 即可保留 markdown 格式（飞书原生支持）

## 背景：它是什么，不是什么

AWS DevOps Agent **不是代码 agent**（跟 Claude Code / Copilot 是不同物种），它是**"AI SRE 值班员" + "事件复盘分析师"** 的组合：核心战场是**生产环境事件响应**，不是写代码。

最反常规的设计是**不绑 CloudWatch**：官方一等公民集成了 Datadog / Dynatrace / Grafana / New Relic / Splunk / PagerDuty / ServiceNow，还接 Azure。这说明它的客户画像是已经有成熟 observability 栈的中大型团队。

它输出的不只是"解释"，而是**可被另一个 coding agent 消费的"agent-ready specifications"**——两层架构：上层 AI 理解运维问题并给出规格，下层 coding AI 执行代码修改。

---

## 1. 🥇 告警风暴自动合并（Incident Correlation）

**痛点**：一次真实事故会触发 N 个告警（CPU 高 → 数据库连接耗尽 → API 5xx → 下游超时），on-call 被 paged 5 次、分别建 5 个 ticket、5 个 war room。

**Agent 的做法**：20 分钟 look-back window，新告警进来自动跟进行中的调查做 AI 比对（组件相似度 / 区域 / 时间模式），**同源就合并**到同一个 investigation，只留一条主 ticket。你也能手动 unlink、写自定义 correlation rules。

**实际收益**：值班"噪音"直接砍一大半。这一条就够很多团队买单。

---

## 2. 🥇 事件全流程自动化：从告警到 RCA 到缓解方案

**触发方式有三种**（覆盖所有真实场景）：

- 📥 **Ticketing 集成** —— ServiceNow ticket 一建，自动开调查，findings 回写进 ticket
- 📥 **Webhook** —— PagerDuty / Grafana 等任何能 POST HTTP 的系统
- 📥 **手动** —— web app 里自由文本描述，或选预设（"最近一个告警" / "高 CPU" / "错误率飙升"）

**Agent 产出的链条**：investigation plan → 采集 metrics/logs → root cause 假设 → **mitigation plan**（可执行的缓解建议）

**实际收益**：凌晨 3 点被 page 起来，登进去能直接看到"它已经查了 12 个地方、排除了 8 个、怀疑是 X"——不用自己再重走一遍流程。**MTTR 降低的最大来源**。

---

## 3. 🥈 多平台一体化调查，不强绑 CloudWatch

这条很多人低估了。支持的外部系统：

| 类别 | 支持 |
|---|---|
| 云 | AWS 全区 / AWS 中国 / **Azure（资源 + Azure DevOps）** |
| CI/CD | GitHub（含 Enterprise Server）/ GitLab（含自建） |
| Telemetry | Datadog / Dynatrace / Grafana / New Relic / Splunk |
| Ticket/Chat | PagerDuty / ServiceNow / Slack |
| 自定义 | MCP Server（就是 aws-devops-agent-external-mcp 项目要干的事）+ Agent Client Protocol |

**实际收益**：不用被逼着把 observability 搬到 CloudWatch。**Agent 会跨平台串调查线索**——告警在 Datadog、部署在 GitLab、ticket 在 ServiceNow，它自己把这条链拼起来。

---

## 4. 🥈 Ops Backlog：从"一直救火"转成"系统性消灭复发"

**默认每周**自动把近期所有事故跑一轮分析，输出 4 类改进建议：

- **Observability** —— 告警/日志缺口（这个最容易落地）
- **Infrastructure** —— 容量、架构韧性
- **Governance** —— 部署流程、pipeline、测试
- **Code optimization** —— 应用层错误处理

每条建议带：涉及的历史事件 + 预期影响 + **可以直接喂给 coding agent 的 spec**（Kiro、Claude Code 都能吃）。Keep / Discard / Implemented 打标签；Discard 要写原因——agent 会学，下次不再推类似的。

**实际收益**：把"我知道应该改但永远没时间"的 tech debt 列成可管理的 backlog，**而且每条都有 business case**（关联了哪些事故、影响多大）。对管理者做资源申请特别有用。

---

## 5. 🥉 On-demand Chat：跨控制台的"运维搜索引擎"

自然语言问 infra：

- "How many Lambdas are using Python 3.8?"
- "Do I have any certificates about to expire?"
- "Any 5xx errors in the last hour?"
- "What's the most common cause of incidents last month?"

context-aware：在 Topology 页问跟架构相关，在 Incident 页问跟调查相关。

**实际收益**：**不用在 8 个 AWS 控制台 + 3 个监控平台之间反复跳**。资产盘点、合规检查（证书到期、IAM 异常）这类固定报表需求，直接问就行。

---

## 6. 🥉 Topology 自动建模（Learned Skills: `understanding-agent-space`）

Agent 扫你连进去的账号 + repo + 遥测，**自己生成架构文档**：

- 服务依赖图（component-level）
- 请求链路图（从入口到后端到数据层）
- **代码仓库 ↔ 部署的 container ↔ IaC 定义** 的三方映射
- 每个组件关联的 alarm、dashboard、log group

这些产出以 `SKILL.md` 形式存，agent 自己会用，你也能看。

**实际收益**：**新人上手周期**从"读 3 周 wiki"变成"问 agent"。老系统没人敢动的部分，至少有一份 AI 生成的路径图。

---

## 7. 运维知识资产化（Skills / `SKILL.md`）

把团队的 runbook、SOP、"踩过的坑"写成 `SKILL.md`，上传到 Agent Space。之后 agent 在调查到触发场景时**自动激活**相应 skill，按你们的 SOP 走。等于把资深 SRE 的经验编译进 AI。

相比传统 Confluence runbook 的优势：**agent 会执行**（通过你连进去的 MCP server / AWS API），不只是"给人看的文档"。

---

## 但要说清楚它**不能做什么**

| 能力 | 状态 |
|---|---|
| 直接改代码/提 PR | ❌ 它**只出规格**，实际代码修改得交给 coding agent |
| GCP 一等公民集成 | ❌ 没有，得靠 MCP 自建 |
| 读 repo 里的 `AGENTS.md` | ❌ 必须用 `SKILL.md` + console/zip 上传 |
| 无 telemetry 团队也能用 | ⚠️ 效果**严重依赖**已有的告警/日志/metrics 覆盖度 |
| 零配置见效 | ❌ 真正发挥价值前得连账号、repo、CI/CD、告警源、ticketing 至少 3-4 类 |

---

## 我的判断：什么团队最值得上

**高 ROI**：

- 有正经 on-call rotation、每月 ≥ 10 次真实事件的中大型运维团队
- 已经在用 Datadog / Splunk / ServiceNow 这类商业栈（它的价值一半在"跨平台串线索"）
- 多云或 AWS 多账号环境（它的 topology 建模对复杂拓扑帮助最大）

**低 ROI / 先别急**：

- 小团队、事件少（每次都能人工 handle，自动化没意义）
- 纯 AWS 单账号 + CloudWatch 裸跑（它的跨平台优势用不上，就是个增强版 Q Developer）
- observability 还没铺好的团队（先解决数据问题再考虑 agent）

---

## 参考资料

- [AWS DevOps Agent 用户指南](https://docs.aws.amazon.com/devopsagent/latest/userguide/)
- [Autonomous incident response](https://docs.aws.amazon.com/devopsagent/latest/userguide/working-with-devops-agent-autonomous-incident-response.html)
- [Proactive incident prevention](https://docs.aws.amazon.com/devopsagent/latest/userguide/working-with-devops-agent-proactive-incident-prevention.html)
- [DevOps Agent Skills (SKILL.md 规范)](https://docs.aws.amazon.com/devopsagent/latest/userguide/about-aws-devops-agent-devops-agent-skills.html)
- [Learned Skills](https://docs.aws.amazon.com/devopsagent/latest/userguide/about-aws-devops-agent-learned-skills.html)
- [产品页](https://aws.amazon.com/devops-agent/) | [FAQ](https://aws.amazon.com/devops-agent/faqs/)
