# C9 — Five-Source Multi-Signal RCA (parallel data fan-out)

> Design reference: `../../docs/superpowers/specs/2026-05-13-china-region-10-wow-cases-design.md` § 2 Case 9

## TL;DR

A more aggressive version of C2: not just one root cause, but **two
independent ones** that both contribute to the latency spike. We layer
**L4 (unindexed query)** and **L9 (pod CPU limit pinned to 100m)** at
the same time, and ask the agent for "a complete correlation analysis".
The agent fans out to **five data sources in parallel** — CloudWatch
metrics, RDS Performance Insights, EKS Container Insights (CPU
throttling %), ALB target health, and GitHub commit history — then
reports **two independent root causes** with the right priority order.
This is the "tools panel shows 4+ tools, parallel" headline.

## Prereqs

- [ ] Agent Space wired and authenticated; bjs1 MCP healthy
- [ ] GitHub `bjs-todo-api` repo connected (for the commit-history hop)
- [ ] **`china-incident-rca`** skill uploaded (4-axis report; this case
      uses Axis 1-3 plus the multi-source fan-out pattern)
- [ ] EKS `todo-api` running at baseline `v1.2.3` image
- [ ] CPU limit at sane baseline (~500m) — verify before injecting:

```bash
unset AWS_PROFILE AWS_REGION
kubectl --context bjs1 -n bjs-web get deployment todo-api \
  -o jsonpath='{.spec.template.spec.containers[0].resources.limits.cpu}{"\n"}'
# expect: not "100m" (e.g. 500m or unset)
```

- [ ] CloudWatch alarm `bjs-web-p99-latency-high` is `OK`
- [ ] RDS Performance Insights enabled on `bjs-todo-db`
- [ ] EKS Container Insights enabled on cluster `bjs-web`

## Inject

Inject **both** L4 and L9. Order matters: inject L9 first so the CPU
ceiling is in place before load arrives.

```bash
unset AWS_PROFILE AWS_REGION
cd /Users/ychchen/warren_ws/aws-devops-agent-external-mcp/demo-cases/faults

# 1. L9 — pin pod CPU limit to 100m (induces throttling under load)
./inject-L9-pod-cpu-limit.sh

# 2. L4 — drive 50 RPS against the unindexed search endpoint
./inject-L4-unindexed-query-load.sh
```

Wait ~3-5 minutes. Both effects compound: queries go slow because of
the missing index, **and** the pod throttles because the CPU limit is
too low to handle the queue. p99 latency rises faster and stays elevated
longer than C2 alone would.

Verify:

```bash
# CPU limit should now be 100m
kubectl --context bjs1 -n bjs-web get deployment todo-api \
  -o jsonpath='{.spec.template.spec.containers[0].resources.limits.cpu}{"\n"}'
# expect: 100m

# Alarm fired
aws --profile ychchen-bjs1 --region cn-north-1 \
  cloudwatch describe-alarms --alarm-names bjs-web-p99-latency-high \
  --query 'MetricAlarms[0].StateValue' --output text
# expect: ALARM
```

## Trigger / Query

Type into Agent Space:

```
bjs-todo-api p99 latency has gone from 50ms to 500ms in the last 15 minutes. Give me a complete correlation analysis — look at every relevant data source and tell me ALL the root causes.
```

(Or shorter: `过去 15 分钟 bjs-todo-api 延迟从 50ms 飙到 500ms，到底什么原因，给我一份完整的关联分析`)

The phrasing is intentional: *"every relevant data source"* and *"ALL
the root causes"* nudge the agent to fan out and to look for more than
one.

## Expected Agent Behavior

The agent must dispatch **5 parallel investigations** (or as close as
the platform supports) and report **two distinct root causes**.

- **Source 1 — CloudWatch latency metric**: anomaly start time T,
  spike magnitude
- **Source 2 — RDS Performance Insights / pg_stat_statements**: top-N
  queries, finds `WHERE email = ?` with `Seq Scan on users`, very high
  per-call latency
- **Source 3 — EKS Container Insights**: pod CPU usage and CPU throttle
  percentage. CPU throttle % rises sharply once load hits, peaking
  near 80-100%
- **Source 4 — ALB target health**: clean. (The agent should
  explicitly note this — "ALB is fine, ruled out".)
- **Source 5 — GitHub commit history**: identifies the recent commit
  that introduced the unindexed query (~25 minutes prior to the spike)

The agent then **separates two independent root causes**:

1. **Primary root cause (~70% of impact)**: the missing `users.email`
   index. Fix: `CREATE INDEX idx_users_email ON users(email);`
2. **Amplifying root cause (~30%)**: the pod CPU limit `100m` makes
   the existing slow queries even slower because the pod can't keep
   up with retries. Fix: raise CPU limit to 500m+, or remove the limit.

Output includes a **timeline view** that overlays the 5 source signals
on the same time axis (latency curve, throttle %, query rate, deploy
event, etc.).

## Acceptance Criteria

- [ ] Agent invoked **at least 4 distinct MCP / data-source tools**
      (visible in tools panel) — ideally 5
- [ ] Output **explicitly distinguishes two independent root causes**
      and labels them by priority (primary vs amplifying, or 70/30,
      or "main cause / contributing factor")
- [ ] Each root cause has a concrete fix recommendation
- [ ] Fixes are **sorted by priority** in the output
- [ ] Output includes a **timeline view** combining ≥3 of the 5
      sources on a shared time axis
- [ ] ALB is named as **ruled-out** evidence (showing the agent
      doesn't just report what's broken — it also reports what's NOT
      broken)

## Screenshots to capture

Save under `blog/screenshots/`:

1. `case-9-tools-panel-5-sources.png` — Agent Space tools-used panel
   showing ≥4 (ideally 5) parallel tool calls — **headline shot**
2. `case-9-timeline-overlay.png` — the agent's combined timeline view
   with multiple signals
3. `case-9-two-root-causes.png` — the section of the output declaring
   the two independent root causes with priority
4. `case-9-fix-recommendations-sorted.png` — the prioritized fix list
5. `case-9-alb-ruled-out.png` — the line where the agent explicitly
   rules out ALB target health
6. `case-9-rds-pi-evidence.png` — RDS Performance Insights screenshot
   referenced by the agent

## Recover

Recover **both** L4 and L9, in reverse order:

```bash
unset AWS_PROFILE AWS_REGION
cd /Users/ychchen/warren_ws/aws-devops-agent-external-mcp/demo-cases/faults

# 1. Stop the load first
./recover-L4-unindexed-query-load.sh

# 2. Restore CPU limit
./recover-L9-pod-cpu-limit.sh
```

Verify recovery:

```bash
kubectl --context bjs1 -n bjs-web get deployment todo-api \
  -o jsonpath='{.spec.template.spec.containers[0].resources.limits.cpu}{"\n"}'
# expect: NOT "100m"

aws --profile ychchen-bjs1 --region cn-north-1 \
  cloudwatch describe-alarms --alarm-names bjs-web-p99-latency-high \
  --query 'MetricAlarms[0].StateValue' --output text
# expect: OK (within ~3 minutes)
```

> **As with C2, do NOT apply the index fix here** if you're planning
> to run C7 next — C7 needs the bug to still exist so the spec → coding
> agent loop has something to do.

## Common pitfalls

- **Agent reports only the index issue (misses the CPU throttle)** —
  this is the most common failure mode. The query phrasing matters: if
  you ask "why is latency high?" the agent finds the most obvious
  cause and stops. The phrase **"ALL the root causes"** in the query
  is what nudges fan-out. If the agent stops at one cause, follow up:
  *"Is there anything else? Is the pod itself healthy?"*
- **CPU throttle metric not visible** — Container Insights must be
  enabled on the cluster for `pod_cpu_throttling_ratio` (or
  equivalent) to appear in CloudWatch. If not enabled, the agent will
  miss source 3. Verify with:
  ```bash
  aws --profile ychchen-bjs1 --region cn-north-1 \
    cloudwatch list-metrics --namespace ContainerInsights \
    --metric-name pod_cpu_utilization --max-items 1
  ```
- **Tools panel shows sequential, not parallel** — the agent's runtime
  may serialize MCP calls. The case still passes if ≥4 distinct tools
  were used, but the "parallel fan-out" screenshot is more impressive
  if calls are concurrent. This is a runtime characteristic, not
  something we can force from the user side.

## Notes for blog write-up

C9 is the upgrade of v1's "VPC compare" demo (which only used 2 data
sources) into the production version: **5 data sources, 2 independent
root causes, prioritized**. It's the case that proves the agent isn't
just answering the question — it's modeling the full system.

Suggested framing:

> *"There's no single root cause. The agent doesn't pick the most
> convenient explanation and stop — it correlates five signals,
> reports two independent causes with priority, and tells you which
> one to fix first."*

The headline screenshot is the **tools panel with 5 sources**. Pair
it with a quote box: *"Five tools, one minute, two root causes."*
