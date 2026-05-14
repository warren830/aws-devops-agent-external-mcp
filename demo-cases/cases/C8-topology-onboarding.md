# C8 — Topology-Driven Onboarding Query (read-only Convenience demo)

> Design reference: `../../docs/superpowers/specs/2026-05-13-china-region-10-wow-cases-design.md` § 2 Case 8

## TL;DR

A **read-only** demo. No fault is injected. We simulate a new SRE asking
*"what touches the `etl-state` DynamoDB table?"* and watch the agent
answer with a complete dependency map — upstream Lambda + SQS, the ECS
service that reads/writes, the IAM role granting access, the alarms that
watch it, and the most recent deploy that touched it — all from
**learned topology**, with **zero clarifying questions**. This is the
*Convenience* (6C) headline: the agent already knows.

## Prereqs

- [ ] Agent Space wired and authenticated; china account MCP healthy
- [ ] **Topology learned** — the demo infrastructure has been deployed
      for at least 24 hours so the agent's learned-skills sweep has
      indexed both accounts. (If the infra is fresh, the agent will fall
      back to live MCP calls — the case still works but the screenshot
      "Source: learned topology" is missing.)
- [ ] All baseline resources present and healthy (no leftover faults
      from C3 / C5 / C10 — those would mutate the very services we're
      asking about):
  - DynamoDB `etl-state` in `PAY_PER_REQUEST` mode
  - ECS `etl-worker` 1/1 Running
  - SQS `etl-jobs` exists, queue depth ≈ 0
  - Lambda `etl-trigger` exists, schedule enabled
  - IAM role `etl-task-role` (or whatever the terraform names the ECS
    task IAM role) attached to the ECS task definition
  - CloudWatch alarms `dynamodb-etl-state-throttle` etc. exist and `OK`

```bash
unset AWS_PROFILE AWS_REGION
aws --profile ychchen-china --region cn-northwest-1 \
  dynamodb describe-table --table-name etl-state \
  --query 'Table.BillingModeSummary.BillingMode || `PAY_PER_REQUEST`' --output text
# expect: PAY_PER_REQUEST
aws --profile ychchen-china --region cn-northwest-1 \
  ecs describe-services --cluster china-data --services etl-worker \
  --query 'services[0].runningCount' --output text
# expect: 1
```

## Inject

**This case is read-only. Skip injection entirely.**

If you ran C3 or C10 earlier in the session and didn't recover, run the
recover scripts first so the topology you describe is the clean baseline:

```bash
unset AWS_PROFILE AWS_REGION
cd /Users/ychchen/warren_ws/aws-devops-agent-external-mcp/demo-cases/faults
./recover-L5-etl-oom-ddb-throttle.sh   # if C3 was active
./recover-L2-s3-public-and-ecs-scale.sh # if C10 was active
```

## Trigger / Query

Type into Agent Space:

```
List every resource connected to the etl-state DynamoDB table in the china account: upstream and downstream services, IAM permissions, monitoring alarms, and the most recent deploy that touched it. Draw the topology.
```

(Or shorter: `列出连接到 etl-state 这张 DynamoDB 表的所有资源，包括上下游服务、IAM 权限、监控告警、最近的部署变更`)

## Expected Agent Behavior

The agent answers **without asking which cluster or which region**, and
without making the user supply any context. It draws on learned topology
(or, if topology isn't pre-learned, parallel MCP queries — same result).

Expected response structure:

- **Direct readers/writers**:
  - ECS service `etl-worker` (cluster `china-data`) — writes via
    DynamoDB SDK
- **Upstream triggers**:
  - Lambda `etl-trigger` (daily 00:00 UTC EventBridge schedule)
  - SQS queue `etl-jobs` (Lambda → SQS → ECS task pulls)
- **IAM permissions**:
  - Role `etl-task-role` (or terraform-given name) with policy granting
    `dynamodb:PutItem`, `dynamodb:GetItem`, `dynamodb:UpdateItem` on
    `arn:aws-cn:dynamodb:cn-northwest-1:284567523170:table/etl-state`
- **Monitoring**:
  - CloudWatch alarms `dynamodb-etl-state-throttle`,
    `dynamodb-consumed-wcu` (or whichever exist)
- **Most recent deploy**:
  - The last ECS task-definition revision and the CodePipeline / commit
    that produced it (if the GitHub integration is connected, it should
    say "task definition v8 deployed N days ago via CodePipeline run X
    triggered by commit Y")
- **Topology diagram** — mermaid or ASCII showing the chain
  `EventBridge → Lambda etl-trigger → SQS etl-jobs → ECS etl-worker
  → DynamoDB etl-state` with the IAM role and alarms annotated.

## Acceptance Criteria

- [ ] Agent lists **at least 6 distinct related resources**
- [ ] At least one **IAM role + policy reference** is named (the role
      ARN or a paraphrase of the policy actions)
- [ ] At least one **CloudWatch alarm** is named explicitly
- [ ] At least one **recent deploy event** is referenced (task
      definition revision, CodePipeline run, or git commit)
- [ ] **No clarifying questions** asked by the agent — it does not
      reply with "which region?" or "which cluster?"
- [ ] Output includes a **topology diagram** (mermaid or ASCII)

## Screenshots to capture

Save under `blog/screenshots/`:

1. `case-8-query-input.png` — the user's natural-language question in
   Agent Space, exactly as typed
2. `case-8-answer-full.png` — the agent's full answer
3. `case-8-topology-diagram.png` — close-up of the mermaid/ASCII
   topology drawing
4. `case-8-iam-permission-section.png` — close-up of the IAM role +
   policy actions
5. `case-8-no-clarifying-questions.png` — the conversation thread
   showing **one** user message and **one** agent answer (no back-and-forth)

## Recover

**Nothing to recover.** This is a read-only case. Move on to the next.

## Common pitfalls

- **Agent asks a clarifying question** — defeats the entire
  Convenience point. Most common cause: ambiguous phrasing of the
  question. If the agent comes back with "in which account?", re-issue
  with the explicit hint *"in the china account, cn-northwest-1"* and
  capture the second exchange instead. Better still: phrase the
  question with the table name only (it's globally unique within the
  account, so the agent shouldn't need disambiguation).
- **Stale topology** — if the demo infra was deployed in the last 24
  hours, learned-skills indexing may not have completed. The agent
  will fall back to live MCP queries, which still give the right
  answer but slower. Wait 24+ hours after deploy before recording the
  blog screenshot.
- **Faulty baseline** — if C3 or C5 or C10 is still active, the
  topology answer will include the broken state (e.g. ECS desired
  count = 5). That's not wrong but it muddies the "look at this
  beautiful clean dependency graph" framing. Recover all faults
  before recording.

## Notes for blog write-up

C8 is the **Convenience** (6C #3) showcase. The point is not what the
agent says — anyone with `aws cli` access can list the connections —
but **how little the human had to say**. One question. No setup. No
"please specify the cluster name". The agent already knew.

Lead screenshot: the conversation panel with **one user message and
one agent message**, side-by-side with the topology diagram.

Suggested framing for the blog:

> *"This is what 'topology-aware' actually means in production. A new
> SRE asks 'what touches this table?' and gets the dependency graph
> in 30 seconds — IAM, alarms, recent deploys, all of it. No
> clarifying questions, no Confluence rummaging, no asking the
> previous engineer who left the company."*

This is the **shortest** of the 10 cases by setup time and the only
one with a "no fault, just show off" framing. Use it as a closing
demo for showing teams what day-to-day query workflow looks like
*after* the incident response demos have already wowed them.
