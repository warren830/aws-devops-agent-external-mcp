# C3 — Multi-Hop Topology RCA (4-hop dependency walk)

> Design reference: `../../docs/superpowers/specs/2026-05-13-china-region-10-wow-cases-design.md` § 2 Case 3

## TL;DR

The ETL pipeline in `cn-northwest-1` looks like it's failing at the ECS
layer (`exit code 137`, OOM-style kills). The naïve answer is "ECS task
broken" — but the **real** root cause is two hops upstream: DynamoDB
`etl-state` is provisioned at 5 WCU and getting throttled, which makes
each task hang on retries until it OOMs. We ask the agent for a root
cause and watch it walk **Lambda → SQS → ECS → DynamoDB**, refusing to
stop at the symptom.

## Prereqs

- [ ] Agent Space wired and authenticated; both bjs1 and china MCP servers
      reachable
- [ ] `china-data` ECS cluster healthy at baseline: `etl-worker` 1/1 Running,
      `report-generator` scaled to 0
- [ ] DynamoDB `etl-state` currently in `PAY_PER_REQUEST` billing mode
      (the inject script flips it to PROVISIONED 5/5)
- [ ] CloudWatch alarms `ecs-etl-task-failures` and
      `dynamodb-etl-state-throttle` are in `OK`
- [ ] No leftover messages on SQS `etl-jobs` (queue depth = 0)

```bash
unset AWS_PROFILE AWS_REGION

aws --profile ychchen-china --region cn-northwest-1 \
  dynamodb describe-table --table-name etl-state \
  --query 'Table.BillingModeSummary.BillingMode' --output text
# expect: PAY_PER_REQUEST  (or empty/None on a fresh on-demand table)

aws --profile ychchen-china --region cn-northwest-1 \
  ecs describe-services --cluster china-data --services etl-worker \
  --query 'services[0].runningCount' --output text
# expect: 1
```

## Inject

```bash
unset AWS_PROFILE AWS_REGION
cd /Users/ychchen/warren_ws/aws-devops-agent-external-mcp/demo-cases/faults
./inject-L5-etl-oom-ddb-throttle.sh
```

What the script does (verify by tailing it):
1. Switches `etl-state` from PAY_PER_REQUEST → PROVISIONED 5 RCU / 5 WCU
   (waits for the table state to settle).
2. Updates the ECS service `etl-worker` desired-count from 1 → 5 to drive
   parallel writers.
3. Pushes ~100 messages onto SQS `etl-jobs` so the workers have something
   to chew on.
4. Waits for the alarms `ecs-etl-task-failures` and
   `dynamodb-etl-state-throttle` to flip.

Verify the symptoms before querying the agent:

```bash
aws --profile ychchen-china --region cn-northwest-1 \
  cloudwatch describe-alarms \
    --alarm-names ecs-etl-task-failures dynamodb-etl-state-throttle \
    --query 'MetricAlarms[].{Name:AlarmName,State:StateValue}' --output table
# expect: both ALARM
aws --profile ychchen-china --region cn-northwest-1 \
  ecs list-tasks --cluster china-data --service-name etl-worker \
  --desired-status STOPPED --max-items 5
# expect: several stopped tasks
```

## Trigger / Query

Type into Agent Space:

```
The ETL pipeline in the china account is failing — tasks keep dying. What's the root cause? Walk the dependency chain.
```

(Or shorter: `china 账号 ETL 失败了，根因是什么`)

## Expected Agent Behavior

The agent must walk **all four hops**, with concrete evidence at each:

- **Hop 1 — ECS**: calls `ecs:ListTasks` + `DescribeTasks` on `etl-worker`.
  Sees many `STOPPED` tasks with `exit code 137` (OOM-killed). A naïve
  agent would stop here. This one shouldn't.
- **Hop 2 — Upstream (SQS / Lambda trigger)**: looks at SQS metrics
  (`ApproximateNumberOfMessagesVisible`, `NumberOfMessagesReceived`) for
  `etl-jobs`. Sees the queue is being consumed (so SQS is fine) but the
  surge in receives correlates with the failures.
- **Hop 3 — Task logs**: pulls `awslogs` for the failed tasks and finds
  `ProvisionedThroughputExceededException` lines from the DynamoDB SDK
  along with retries piling up before the OOM kill.
- **Hop 4 — DynamoDB**: calls CloudWatch metrics
  `ConsumedWriteCapacityUnits` for `etl-state`. Sees the metric pinned at
  the **5 WCU ceiling** — clear throttling.
- **Conclusion**: root cause is **DynamoDB provisioned capacity**, not
  ECS. The OOM is a downstream effect of SDK retries from throttling.
- **Fix recommendation**: switch `etl-state` back to `PAY_PER_REQUEST`
  **or** raise WCU to a level that matches incoming concurrency.

The agent should output a **dependency graph** (mermaid or ASCII) of the
4 hops, ideally with the metric/log evidence pinned to each edge.

## Acceptance Criteria

- [ ] Agent's response **draws or describes a 4-hop dependency chain**:
      `Lambda → SQS → ECS → DynamoDB`
- [ ] Concrete evidence is cited at **each hop** (a metric value, log
      line, or task ARN — not generic prose)
- [ ] Final root cause is **DynamoDB throttling**, not "ECS task is broken"
      or "tasks need more memory"
- [ ] Recommended fix specifies one of: switch to on-demand billing, or
      raise WCU/RCU; mentioning the 5 WCU current ceiling
- [ ] Agent invoked tools across **at least 3 services**: ECS, CloudWatch
      (incl. SQS metrics), DynamoDB

## Screenshots to capture

Save under `blog/screenshots/`:

1. `case-3-tools-panel-multihop.png` — Agent Space tools-used panel
   showing the sequence of MCP calls (ecs → cw → ddb)
2. `case-3-dependency-graph.png` — The mermaid/ASCII 4-hop diagram
   from the agent's response
3. `case-3-ecs-stopped-tasks.png` — ECS console (or CLI output) showing
   the stopped tasks with exit code 137
4. `case-3-ddb-throttle-curve.png` — CloudWatch graph for
   `ConsumedWriteCapacityUnits` against the 5-WCU provisioned line
5. `case-3-rca-final-conclusion.png` — Agent's final paragraph
   declaring DynamoDB the root cause and ECS the symptom

## Recover

```bash
unset AWS_PROFILE AWS_REGION
cd /Users/ychchen/warren_ws/aws-devops-agent-external-mcp/demo-cases/faults
./recover-L5-etl-oom-ddb-throttle.sh
```

The recover script:
1. Switches `etl-state` back to PAY_PER_REQUEST and waits for table state
   to settle.
2. Drains SQS (purge or wait-for-empty) and resets `etl-worker`
   desired-count to 1.
3. Confirms both CloudWatch alarms return to `OK`.

Verify after recovery:

```bash
aws --profile ychchen-china --region cn-northwest-1 \
  dynamodb describe-table --table-name etl-state \
  --query 'Table.BillingModeSummary.BillingMode' --output text
# expect: PAY_PER_REQUEST
aws --profile ychchen-china --region cn-northwest-1 \
  cloudwatch describe-alarms \
    --alarm-names ecs-etl-task-failures dynamodb-etl-state-throttle \
    --query 'MetricAlarms[].StateValue' --output text
# expect: OK OK
```

## Common pitfalls

- **DynamoDB billing-mode switch is asynchronous** — `update-table` returns
  immediately but the table can stay in `UPDATING` for ~30 seconds. If you
  inject the next mutation too fast you'll get
  `ResourceInUseException`. The script handles this with a wait loop;
  if you trigger steps manually, sleep until `TableStatus = ACTIVE`.
- **The agent stops at hop 1** — this is the failure mode the case is
  designed to expose. It usually means either (a) the task logs aren't
  reachable through our MCP, or (b) the agent's prompt didn't push it to
  walk upstream. Check that the awslogs group
  `/ecs/china-data/etl-worker` is queryable from your MCP credentials.
  If it stops, ask explicitly: *"What does the task log say before the
  exit? What does DynamoDB look like over the same window?"*
- **Pre-existing throttle metric noise** — if you ran C3 recently and
  didn't recover cleanly, the throttle metric may still be flat at zero
  even with provisioned 5 WCU because no one is writing yet. The L5 script
  pushes ~100 SQS messages to guarantee write pressure; if you skipped
  that step, the agent may report "DynamoDB looks fine".

## Notes for blog write-up

The headline screenshot is the **dependency graph** with all four nodes
annotated and DynamoDB circled in red. The reader's mental model usually
stops at the failing component (ECS) and the agent's job here is to push
past it. Pair this case with a one-line caption like:

> *"The agent doesn't ask 'what failed?' — it asks 'what failed because
> something else failed first?'. That's the topology-aware difference."*
