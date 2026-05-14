# C10 — Cost Anomaly → Ops Backlog (FinOps closed loop)

> Design reference: `../../docs/superpowers/specs/2026-05-13-china-region-10-wow-cases-design.md` § 2 Case 10

## TL;DR

Simulate a "Friday-night auto-scale gone wrong" in the china account:
ECS service `etl-worker` has its desired-count cranked from 1 to 20,
runs 60+ task-hours over the weekend, and S3 bucket
`china-data-output-4fca6718` is flipped to public (a separate sin tracked
in the same scenario). Monday morning, ask the agent to run a **cost
anomaly evaluation** with the `cross-account-cost-attribution` skill.
The agent surfaces the spend spike, attributes it precisely to the ECS
scale event, finds the IAM principal that triggered it (via CloudTrail),
and emits an **ops backlog** of three concrete fixes: hard-cap on ECS
auto-scale, Cost Anomaly Detection alarm, weekend budget alert. FinOps,
fully closed-loop.

## Prereqs

- [ ] Agent Space wired and authenticated; china account MCP healthy
- [ ] **`cross-account-cost-attribution`** skill uploaded (zip at
      `skills/cross-account-cost-attribution.zip`)
- [ ] Cost Explorer enabled on the china account (must have been on for
      ≥48 hours so there is real cost data — Cost Explorer data lags)
- [ ] CloudTrail in china account enabled and storing events to S3 (so
      the agent can find the `UpdateService` call)
- [ ] Baseline ECS state: `etl-worker` desired-count = 1
- [ ] Baseline S3 state: `china-data-output-4fca6718` is **private** with
      Public Access Block enforced (the inject script flips it)

```bash
unset AWS_PROFILE AWS_REGION

aws --profile ychchen-china --region cn-northwest-1 \
  ecs describe-services --cluster china-data --services etl-worker \
  --query 'services[0].desiredCount' --output text
# expect: 1

aws --profile ychchen-china --region cn-northwest-1 \
  s3api get-public-access-block --bucket china-data-output-4fca6718 \
  --query 'PublicAccessBlockConfiguration.BlockPublicAcls' --output text 2>/dev/null
# expect: True (block-public-acls is on)
```

## Inject

For the most realistic demo, **inject on Friday afternoon** so weekend
spend actually accumulates and Monday's Cost Explorer data shows a real
spike. If you don't have that timeline, the script still injects the
state — the cost data just won't be as dramatic.

```bash
unset AWS_PROFILE AWS_REGION
cd /Users/ychchen/warren_ws/aws-devops-agent-external-mcp/demo-cases/faults
./inject-L2-s3-public-and-ecs-scale.sh
```

What it does:
1. Removes Public Access Block on `china-data-output-4fca6718` and
   applies a public-read bucket policy. (This is the security half of
   the case; the agent should also flag it.)
2. Updates ECS service `etl-worker` desired-count from 1 → 20.
3. Logs both `UpdateService` and S3 mutation events to CloudTrail.

Verify the state landed:

```bash
aws --profile ychchen-china --region cn-northwest-1 \
  ecs describe-services --cluster china-data --services etl-worker \
  --query 'services[0].desiredCount' --output text
# expect: 20

aws --profile ychchen-china --region cn-northwest-1 \
  s3api get-bucket-policy --bucket china-data-output-4fca6718 \
  --query 'Policy' --output text | head -c 200
# expect: a policy with Principal: "*" Action: "s3:GetObject"
```

For the cost-spike to be visible, **let it run for 48-72 hours** before
running the query. If you must demo same-day, make this clear in the
narration ("imagine three days have passed; here's what Cost Explorer
shows").

## Trigger / Query

In Agent Space (Evaluation type if available, else Investigation), type:

```
Run a cost anomaly check on the china account for the past week. Find any unusual spend, attribute it to the responsible resource and the IAM principal who caused it, and produce an ops backlog with concrete prevention recommendations.
```

(Or shorter: `本周 china 账号 cost 周末有没有异常，生成 ops backlog`)

## Expected Agent Behavior

The agent activates `cross-account-cost-attribution` and runs:

- **Step 1 — Cost Explorer**: pulls the past 7 days of cost data,
  identifies the weekend (Sat-Sun) is **5x higher than the weekday
  baseline**.
- **Step 2 — Service breakdown**: groups the spike by service. ECS
  Fargate accounts for **~80%** of the anomalous spend.
- **Step 3 — ECS investigation**: calls `ecs:DescribeServices` and
  finds `etl-worker` desired-count = 20. Calls
  `ecs:DescribeServices --include EVENTS` and reads service-event log
  for the scale-up moment.
- **Step 4 — CloudTrail attribution**: looks up the
  `ecs:UpdateService` call against `etl-worker` in CloudTrail. Finds
  the **principal ARN** (likely the demo account's own IAM identity)
  and the **timestamp** (Friday evening).
- **Step 5 — Ops backlog**: emits 3 concrete recommendations:
  1. **ECS service-level cap** — set `maxCapacity` (or scaling
     policy upper bound) on `etl-worker` to e.g. `5`. *Expected
     savings: ~75% of weekend cost.*
  2. **Cost Anomaly Detection** — enable it on the china account
     with email/SNS notification. *Expected savings: faster MTTD on
     future cost incidents.*
  3. **Budget alert** — create a daily budget alert with a weekend
     threshold 50% lower than weekday. *Expected savings: catches
     the next regression before Monday.*
- The S3 public-bucket finding should also surface as a related
  security alert (bonus, the case is officially about cost — but the
  inject script created two faults, so both should be visible).

## Acceptance Criteria

- [ ] Cost spike is **accurately attributed to ECS Fargate** (not
      misattributed to RDS, S3, etc.)
- [ ] Agent identifies the **specific `UpdateService` event** in
      CloudTrail with the IAM principal **and** timestamp
- [ ] Ops backlog contains **at least 3 actionable recommendations**
- [ ] Each recommendation includes an **expected savings estimate**
      (in % or absolute terms)
- [ ] Recommendations are **prioritized** (the hard-cap should be #1)
- [ ] Bonus: agent flags the S3 public-bucket finding as a related
      issue (security, not cost-attributed)

## Screenshots to capture

Save under `blog/screenshots/`:

1. `case-10-cost-explorer-spike.png` — the agent's Cost Explorer
   query result showing the 5x weekend spike
2. `case-10-service-breakdown.png` — pie or bar chart attributing
   the spike to ECS Fargate
3. `case-10-cloudtrail-attribution.png` — agent's reference to the
   `UpdateService` event with principal + timestamp visible
4. `case-10-ops-backlog-3-recommendations.png` — the markdown
   ops backlog with 3 recommendations and savings estimates
5. `case-10-s3-public-bonus-finding.png` — the bonus security
   finding for the public S3 bucket (sometimes appears as a
   separate finding, sometimes in a "related issues" footer)
6. `case-10-evaluation-timeline.png` — Agent Space timeline of the
   evaluation run showing all 5 steps

## Recover

```bash
unset AWS_PROFILE AWS_REGION
cd /Users/ychchen/warren_ws/aws-devops-agent-external-mcp/demo-cases/faults
./recover-L2-s3-public-and-ecs-scale.sh
```

The recover script:
1. Re-enables Public Access Block on `china-data-output-4fca6718` and
   removes the public-read bucket policy.
2. Updates ECS service `etl-worker` desired-count back to 1, waits for
   the running tasks to drain.
3. Confirms baseline is restored.

Verify:

```bash
aws --profile ychchen-china --region cn-northwest-1 \
  ecs describe-services --cluster china-data --services etl-worker \
  --query 'services[0].desiredCount' --output text
# expect: 1

aws --profile ychchen-china --region cn-northwest-1 \
  s3api get-public-access-block --bucket china-data-output-4fca6718 \
  --query 'PublicAccessBlockConfiguration.BlockPublicAcls' --output text
# expect: True
```

## Common pitfalls

- **Cost Explorer data lag** — Cost Explorer aggregates with up to
  24h delay. If you inject and immediately query, the agent will
  honestly report "no anomaly visible". For the demo to land, you
  need either (a) inject 48-72h ahead, or (b) explicitly narrate
  "imagine it's Monday morning and we're looking at the past
  weekend's data, here's a representative screenshot..."
- **Wrong service blamed** — sometimes the agent attributes the
  spike to NAT gateway data-transfer cost (Fargate tasks pulling
  ECR images and writing logs through NAT). That's not technically
  wrong but it misses the root cause. If this happens, ask a
  follow-up: *"Drill into the ECS Fargate compute cost specifically.
  How many task-hours did `etl-worker` consume?"*
- **CloudTrail lookup window too narrow** — the agent's CloudTrail
  query may use a 1-hour or 24-hour window by default. The
  `UpdateService` event happened 48+ hours ago. If the agent reports
  "no relevant CloudTrail events", nudge it: *"Look back 7 days in
  CloudTrail for `ecs:UpdateService` calls against `etl-worker`."*
- **Forgot to enable Cost Explorer** — Cost Explorer is opt-in per
  account and needs ~24 hours to backfill before it shows useful
  data. Double-check it's enabled on `ychchen-china` before
  scheduling the demo.

## Notes for blog write-up

C10 is the **FinOps closed-loop** case. It pairs naturally with C6
(prevention checks) as the "predictive" half of the demo:

- C6 = predicted risks **before** they cost money
- C10 = unusual spend **after** it happened, with prevention
  recommendations to stop the next one

Together they show the agent doing both ends of FinOps that AWS
customers traditionally need separate tools (and a dedicated FinOps
team) to handle.

Lead screenshot: the Cost Explorer **5x weekend spike chart** with
the agent's annotation pointing to the `UpdateService` event time.
The headline number is the expected-savings percentage on the
hard-cap recommendation — usually quotable as **"75% of next
weekend's cost saved by one config line"**.

For China readers specifically: native DevOps Agent has FinOps
patterns but no `cn-*` partition — Cost Explorer in cn-north-1 / cn-
northwest-1 is unreachable from the global agent. This case proves
the bridge gets you predictive *and* reactive FinOps inside the
China region for the first time.
