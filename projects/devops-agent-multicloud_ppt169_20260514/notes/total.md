# 01_cover

各位下午好。今天分享的题目是中国区跑通 AWS DevOps Agent 6C 全套能力。这个项目的核心是用 MCP Bridge 加上 Skills 让原生 Agent 看见中国区。我会先讲清楚原生 Agent 在中国区的盲区在哪，然后讲 MCP Bridge 怎么把这个空补上，最后用三个真实跑通的 case 给大家看证据。整个分享大概二十五到三十分钟。

---

# 02_problem

我们先看问题。原生 DevOps Agent 在 us-east-1 跑得很好——6C 框架、Webhook 自主调查、Slack 通知、跨源关联，这些都是开箱即用的。但是同一个 Agent 一旦面对中国区账号，就会哑火。它访问不到 cn-* 资源，因为 IAM 和 STS 的信任链不通，CloudWatch 告警也没法直接打到它的 Webhook 上。最有意思的是，Agent 自己在 thinking 字段里写了一句话——中国区账号不在 enabled associations 里——这是它自己承认的盲区。

---

# 03_significance

这个项目的意义可以用一个数字说清楚。在我们 C2 那个 case 里，Agent 一次 incident 调查通过 MCP Bridge 调用了九十八次中国区 AWS API，零次绕过 Bridge。这是公开资料里第一次让 6C 能力完整落到中国区，靠的就是三件事：MCP Bridge 架构、九个自定义 Skill、三个真实 case 的端到端闭环。

---

# 04_multicloud_landscape

往大了讲，现在很多团队都不只跑一朵云。我们这个 demo 涉及三朵云，实际是六个账号——AWS 全球区一个主账号承载 Agent Space，AWS 中国区两个账号承载真实业务，剩下还有阿里云和 GCP 在仓库里有占位。所有不在 us-east-1 主账号原生关联里的账号，都需要 Bridge——这就是项目要解决的现实。

---

# 05_mcp_bridge_arch

这张图是项目的核心架构。Hub 是 us-east-1 EKS 上跑的 MCP server pods，由 Agent Space 直接调用。两条 Spoke 分别接到中国区两个账号，每个 MCP pod 自己持有该 cn 账号的 AK/SK，Agent 一调它就用 cn 凭证跑 cn API。整个跨 partition 的复杂性被 MCP 这层接口屏蔽掉了——Agent 用着像调一个普通 region 的 API。

---

# 06_agent_thinking_quote

这一页是直接证据。Agent 在它的内部 thinking 字段里直接写："China accounts aren't directly in the enabled associations; instead they're accessed through the custom MCP servers"——也就是中国区账号不在原生关联里，要靠自定义 MCP server 访问。这句话有三个含义：第一，原生路径确实有限制；第二，"自定义 MCP" 就是我们部署的 Bridge；第三，每一次 cn API 调用都被 MCP server 的 access log 完整记录下来，可以审计。

---

# 07_skills_pyramid

讲完 Bridge 是能力层，再来看 Skill 是策略层。一共九个 Skill，分三层。底下 Foundation 层是路由表——告诉 Agent aws-cn 是宁夏、aws-cn-2 是北京——所有上层 Skill 都隐式依赖它。中间分析层和 Pipeline 层，分析层在用户主动 query 时激活，Pipeline 层 webhook 触发时按 triage→rca→mitigation 顺序串起来。最上面那个 cn-partition-arn-routing 是补 Agent 的领域知识——Agent 经常踩 partition 的坑，这个 Skill 帮它纠正。

---

# 08_skill_does_doesnt

这页讲 Skill 能做和不能做的边界。能做的：注入领域知识、统一 RCA 输出、规约 Mitigation 模板、加锁审核协议——所有 Mitigation 命令都要用户显式输入 approve step 几才执行，单步授权抗 LLM 语义漂移。不能做的：Skill 不替代 MCP，因为 MCP 是能力来源；不替代 Webhook 链路，因为告警进不来 Skill 也激活不了；不替代 Agent Space console 配置——OAuth、Webhook URL 生成这些。一句话总结：MCP 给能力，Skill 给策略，缺一不可。

---

# 09_c1_chapter

Part 4 进入三个真实 case。第一个是 Webhook 自主调查。这个 case 的关键词是"人没碰按钮"——alarm 触发后九十秒内 Agent 全程接管，给出 RCA 和 Mitigation Plan，并在 Slack 自动投递。整个过程零人工 query。

---

# 10_c1_flow

具体看 C1 的流程。我们注入 L6 故障——把 EKS deployment 的 image tag 改成不存在的 v1.2.4-DOES-NOT-EXIST。三十秒内 Pod 进入 ImagePullBackOff，九十秒 CloudWatch 告警跳到 ALARM，触发 SNS 推到 Bridge Lambda，Lambda HMAC 签名 POST 到 webhook，得到二百 OK。Agent 立刻接管，跑了十五步调查，给出 RCA 和四阶段 Mitigation 方案。最后一步，每条 Mitigation 命令都带 rollback 和 approval prompt，等用户单步授权才执行——这是 Skill 锁死的 Approval Contract，抗语义漂移。

---

# 11_c1_evidence

C1 不是手画占位——这是真 Agent 真截图。左上 kubectl 终端显示三个 Running 加一个 ImagePullBackOff。右上 CloudWatch 告警状态条从绿色翻红色。左下 RCA 报告引用了具体的 image tag。右下 Slack 频道里 Agent 自主投递了 Investigation started 通知，时间戳十二点十七分。整个链路真实跑通，不是 mock。

---

# 12_c2_chapter

第二个 case 是时间锚定 RCA。这个 case 的关键词是"精确到秒"——Agent 把 ALB p99 突变点锚到一个 k8s pod 的创建时间，时间戳是 05:19:19Z，跟 metric 跳变点完全吻合。同时它平行跑了五个 sub-agent 并行查 ALB、EKS、RDS、CloudTrail、Pod logs，给出三个根因加六个观察项。

---

# 13_c2_data_rca

C2 的关键数据看这页。症状是 ALB p99 超阈值；时间锚定是 c2-load-gen Pod 在 05:19:19Z 创建，跟 p99 从三百三十毫秒突变到七百四十毫秒的时间点精确吻合——这个"精确吻合"是 Agent 自己写在 RCA 里的话；根因是合成负载二万六千 req/min 加 RDS db.t3.micro CPU 百分百饱和加上 users.search 走全表扫描。右边那张大图就是 Agent 写的 RCA 全文，调用了五个 sub-agent，总共九十八次 cn API。

---

# 14_c2_mcp_proof

这是项目最强的铁证。我们抓了 mcp-aws-cn-2 这个 pod 的 access log，把 C2 调查窗口里的所有 API 调用列出来——三十六次 cloudwatch get-metric、二十次 logs start-query、十一次 cloudtrail lookup-events、三次 eks describe-cluster，等等，总共九十八次。每一次都从我们部署的 MCP pod 出去，零次绕过。这就证明了一件事——cn-* AWS API 一百分之百经过 Bridge，整条访问链路完整可审计。

---

# 15_c3_chapter

第三个 case 是多跳拓扑 RCA，跑在中国区第二个账号——宁夏。这个 case 验证的是项目能扩展到第二个 cn 账号。关键词是"四跳追溯"——Agent 沿着 DDB 到 SQS 到 ECS 再到 CloudTrail 一路向上溯源到根因。

---

# 16_c3_4hops

具体看四跳怎么跳的。第一跳 Agent 调 dynamodb describe-table，看到表是 PROVISIONED 五 WCU——它就问"为啥不是按需"，往上溯。第二跳 SQS get-queue-attributes，看到一万四千多条消息积压——再问"谁在写消息"。第三跳 ECS describe-services，发现 desiredCount 从一扩到了五——继续问"谁改的、什么时候"。第四跳 CloudTrail lookup-events，找到了我自己执行 inject 脚本时的那次 ModifyTable 操作，时间戳 07:18:17Z，user-agent 是 ClaudeCode-BH。最酷的是 Agent 通过 user-agent 字段区分了"Terraform 创建" 和 "手动 CLI 变更"，还主动检查了 application-autoscaling 是不是配了兜底——这是真生产 SRE 才会做的细节。

---

# 17_c3_timeline_quote

这一页是 Agent 自己写的根本原因。它说："AdminCYC 在 2026-05-14T07:18:17Z 通过 AWS CLI ClaudeCode-BH 将 etl-state DynamoDB 表的计费模式从 PAY_PER_REQUEST 手动变更为 PROVISIONED 模式仅设置了 5 WCU 的写入容量。CloudTrail 记录显示该表最初由 Terraform 以按需模式创建，2026-05-13T15:07:50Z，不存在节流风险。" 注意它怎么区分了两个时间点：一个是 Terraform 的初始创建，一个是后来的手动变更。这种区分能力就是 6C 框架里 Continuous Learning 的落地。

---

# 18_three_cases_summary

三个 case 对照看。C1 是 webhook 自主，调用了五个 sub-agent，十二分钟出 RCA。C2 是时间锚定，调了九十八次 cn API，九分四十九秒出 RCA。C3 是四跳追溯，调了十四次 cn API，十三分钟收官。三个加起来一百一十多次中国区 AWS API 调用——零次绕过 MCP Bridge。三个 case 用同一套 Bridge 基础设施跑通，验证了项目的可重复性。

---

# 19_thanks

总结一下。我们做的事情就是把 Agent 看不见中国区这个空白补上——MCP Bridge 是能力层，Skills 是策略层，再加上三个真实 case 闭环验证。接下来要做的有三件事：跑剩下的七个 case、写 blog 04 配现场演示 SOP、把同样的 pattern 扩展到阿里云和 GCP。仓库地址在 GitHub warren830 那里，欢迎 issue 和 PR。谢谢大家，问题随时来。
