# 01_cover

各位下午好。今天分享的题目是用 MCP 加 Skill 把 DevOps Agent 的 6C 能力扩展到任何外部资源。这个项目我用中国区做了一套完整 demo 把 pattern 验证下来——目的是给在座的 SA 一份可以直接拿去客户面前讲的资产。我会先讲清楚客户咨询时常碰到的扩展场景，再讲 MCP 加 Skill 的三层职责怎么分工，最后用三个真实跑通的 case 给大家看证据。整个分享大概二十五到三十分钟。

---

# 02_problem

我们先看 SA 日常会被问到的真问题。客户问"能不能用 DevOps Agent 管 X"——X 是中国区、阿里云、自建 K8s、内部 SaaS 还是 Salesforce / Jira / 自研 CMDB——所有这些都不在 native association 范围之内。这一类问题的统一解法都是 MCP 扩展点。中国区只是其中一个具体场景，今天用它做证据，但模式可以直接套到其他任何外部资源。

---

# 03_significance

这个项目交付三件可复用的资产。第一是参考架构——基于 EKS 的 MCP Bridge 加 VPC Lattice Private Connection，整套 Helm chart 客户可以直接用。第二是九个 Skill 模板——按 Foundation 加 Analytical 加 Pipeline 三层组织，客户加自己的领域知识只要套这个模式。第三是三个完整 case 演示——客户 POC 现成素材。中间这个九十八，是 C2 那个 case 里 Agent 一次调查通过 MCP 扩展点调到的 tool call 数——说明 6C 全能力都能走这条路。

---

# 04_multicloud_landscape

往大了讲，现在很多客户都不只跑一朵云。我们这个 demo 涉及三朵云、六个账号——AWS 全球区一个主账号承载 Agent Space，AWS 中国区两个账号承载真实业务，剩下还有阿里云和 GCP 在仓库里有占位。所有不在 us-east-1 主账号原生关联里的账号，都按同一个 Bridge 模式接入——客户的混合云接入计划可以直接复用。

---

# 05_mcp_bridge_arch

这张图是项目的核心架构。Hub 是 us-east-1 EKS 上跑的 MCP server pods，由 Agent Space 通过 VPC Lattice Private Connection 调用。两条 Spoke 分别接到中国区两个账号，每个 MCP pod 自己持有该账号的 AK/SK，安全边界与 Agent 完全解耦。客户要加阿里云、加自建 K8s，加一条 Spoke 就行——同一个 Bridge 模板。

---

# 06_agent_thinking_quote

这一页是直接证据。Agent 在它的内部 thinking 字段里直接写："China accounts aren't directly in the enabled associations; instead they're accessed through the custom MCP servers"——也就是它会主动从 association 列表读到自定义 MCP，然后自己决定路由，不需要 query hint。这句话有三个含义：第一，Agent 主动识别扩展点；第二，Skill 帮它选择正确的 MCP——routing skill 告诉它 aws-cn 对应宁夏、aws-cn-2 对应北京；第三，每一次调用都被 MCP server 的 access log 完整记录下来——合规可证。

---

# 07_skills_pyramid

讲完 Bridge 是能力层，再来看 Skill 是策略层。一共九个 Skill，分三层。底下 Foundation 层是路由表——告诉 Agent 哪个账号对应哪个 MCP——所有上层 Skill 都隐式依赖它。中间分析层和 Pipeline 层，分析层在用户主动 query 时激活，Pipeline 层 webhook 触发时按 triage 到 rca 到 mitigation 顺序串起来。最上面那个 cn-partition-arn-routing 是补 Agent 在 partition 上的领域盲点。

---

# 08_skill_does_doesnt

这页给 SA 一个清晰的答疑模板——客户经常把 Webhook、MCP、Skill 这三件事混淆。Webhook 是入口，把告警拉过来变成 incident，没有它 Agent 自主调查无从触发。MCP 是能力，提供 Agent 调用外部资源的工具，没有它 Agent 看不到 native association 之外的资源。Skill 是策略，告诉 Agent 什么场景调什么、怎么组织输出、加锁审核协议，没有它调查质量大约从百分之三十降到百分之六十的差距。三件事各管各的，缺一不可。

---

# 09_c1_chapter

Part 4 进入三个真实 case。第一个 case 验证的是 6C 里的 Collaboration 和 Convenience——webhook 触发后九十秒内 Agent 全程接管，给出 RCA 和 Mitigation Plan，并在 Slack 自动投递。整个过程零人工 query。

---

# 10_c1_flow

具体看 C1 的流程。我们注入 L6 故障——把 EKS deployment 的 image tag 改成不存在的 v1.2.4-DOES-NOT-EXIST。三十秒内 Pod 进入 ImagePullBackOff，九十秒 CloudWatch 告警跳到 ALARM，触发 SNS 推到 Bridge Lambda，Lambda HMAC 签名 POST 到 webhook，得到二百 OK。Agent 立刻接管，跑了十五步调查，给出 RCA 和四阶段 Mitigation 方案。最后一步，每条 Mitigation 命令都带 rollback 和 approval prompt，等用户单步授权才执行——这是 Skill 锁死的 Approval Contract，抗语义漂移。

---

# 11_c1_evidence

C1 的证据看这页。左上 kubectl 终端显示三个 Running 加一个 ImagePullBackOff。右上 CloudWatch 告警状态条从绿色翻红色。左下 RCA 报告引用了具体的 image tag。右下 Slack 频道里 Agent 自主投递了 Investigation started 通知，时间戳十二点十七分。整个链路真实跑通——客户 POC 直接用这套截图就能讲。

---

# 12_c2_chapter

第二个 case 验证的是 6C 里的 Context——拓扑加跨源关联。关键词是"精确到秒"——Agent 把 ALB p99 突变点锚到一个 k8s pod 的创建时间，时间戳是 05:19:19Z，跟 metric 跳变点完全吻合。同时它平行跑了五个 sub-agent 并行查 ALB、EKS、RDS、CloudTrail、Pod logs，给出三个根因加六个观察项。

---

# 13_c2_data_rca

C2 的关键数据看这页。症状是 ALB p99 超阈值；时间锚定是 c2-load-gen Pod 在 05:19:19Z 创建，跟 p99 从三百三十毫秒突变到七百四十毫秒的时间点精确吻合——这个"精确吻合"是 Agent 自己写在 RCA 里的话；根因是合成负载二万六千 req/min 加 RDS db.t3.micro CPU 百分百饱和加上 users.search 走全表扫描。右边那张大图就是 Agent 写的 RCA 全文，调用了五个 sub-agent，总共九十八次 tool call。

---

# 14_c2_mcp_proof

这一页是 Agent 自主调度模式的可观测证据。我们抓了 mcp-aws-cn-2 这个 pod 的 access log，把 C2 调查窗口里的所有 tool call 列出来——三十六次 cloudwatch get-metric、二十次 logs start-query、十一次 cloudtrail lookup-events、三次 eks describe-cluster，等等，总共九十八次。这个分布说明 Agent 既会反复查同一个 metric 的多个时间窗，也会跨 service 比对变更——深度和广度兼顾。客户问"Agent 调查时到底干了什么"，这就是答案模板。

---

# 15_c3_chapter

第三个 case 验证的是 6C 里的 Continuous Learning 和 Control，跑在中国区第二个账号——宁夏。这个 case 的另一个意义是验证 pattern 在第二个账号上同样跑通。关键词是"四跳追溯"——Agent 沿着 DDB 到 SQS 到 ECS 再到 CloudTrail 一路向上溯源到根因。

---

# 16_c3_4hops

具体看四跳怎么跳的。第一跳 Agent 调 dynamodb describe-table，看到表是 PROVISIONED 五 WCU——它就问"为啥不是按需"，往上溯。第二跳 SQS get-queue-attributes，看到一万四千多条消息积压——再问"谁在写消息"。第三跳 ECS describe-services，发现 desiredCount 从一扩到了五——继续问"谁改的、什么时候"。第四跳 CloudTrail lookup-events，找到了我自己执行 inject 脚本时的那次 ModifyTable 操作，时间戳 07:18:17Z，user-agent 是 ClaudeCode-BH。最酷的是 Agent 通过 user-agent 字段区分了"Terraform 创建"和"手动 CLI 变更"，还主动检查了 application-autoscaling 是不是配了兜底——这是 Continuous Learning 的体现。

---

# 17_c3_timeline_quote

这一页是 Agent 自己写的根本原因。它说："AdminCYC 在 2026-05-14T07:18:17Z 通过 AWS CLI ClaudeCode-BH 将 etl-state DynamoDB 表的计费模式从 PAY_PER_REQUEST 手动变更为 PROVISIONED 模式仅设置了 5 WCU 的写入容量。CloudTrail 记录显示该表最初由 Terraform 以按需模式创建，2026-05-13T15:07:50Z，不存在节流风险。" 注意它怎么区分了两个时间点：一个是 Terraform 的初始创建，一个是后来的手动变更。这种区分能力就是 6C 框架里 Continuous Learning 的落地——Agent 自己想到去看 user-agent 字段。

---

# 18_three_cases_summary

三个 case 对照看。C1 验证 Collaboration 和 Convenience——webhook 自主，五个 sub-agent，十二分钟出 RCA。C2 验证 Context——五数据源关联加时间锚定到秒，九十八次 tool call，九分四十九秒出 RCA。C3 验证 Continuous Learning 和 Control——四跳追溯加区分变更源加主动检查兜底，十四次 tool call，十三分钟收官。三个 case 跑在不同账号、不同资源类型、不同故障类型——同一套 Bridge 加 Skill 模板，全跑通。Pattern 可移植到任何 cloud、任何客户。

---

# 19_thanks

总结一下 SA 怎么用这个项目。第一是 POC 现成素材——三个 case 截图加演讲稿加终端命令直接拿去客户面前讲，十五分钟搭起 demo 环境。第二是参考架构与代码——Bridge Pattern 的 Helm chart、九个 SKILL.md 模板、Webhook bridge Lambda 代码全部开源在 GitHub。第三是扩展场景——阿里云、腾讯云、客户内部 API、on-prem K8s、私有 SaaS，同一套 Bridge pattern 加一条 Spoke 就行。仓库地址在 GitHub warren830 那里，欢迎 issue 和 PR。谢谢大家，问题随时来。
