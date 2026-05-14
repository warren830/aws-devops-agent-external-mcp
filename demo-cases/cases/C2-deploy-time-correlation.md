# C2 — Deploy-Time Correlation (commit-to-incident, second-level precision)

> Design reference: `../../docs/superpowers/specs/2026-05-13-china-region-10-wow-cases-design.md` § 2 Case 2

## TL;DR

A bad commit lands on `main` of `bjs-todo-api`: it adds a `WHERE email = ?`
query against a column with no index. Once load hits the new endpoint, p99
latency on the EKS app spikes. We ask the agent **"why did latency just
spike?"** — and watch it correlate the metric anomaly time with the deploy
time **down to the second**, then dive into the commit diff and surface the
missing index as the root cause. This is the WGU-style time-anchored RCA
that AWS uses on the marquee demo, reproduced for cn-north-1.

## Prereqs

- [ ] Agent Space wired and authenticated
- [ ] GitHub `bjs-todo-api` repo connected (the agent must be able to read
      the recent commit history for this case)
- [ ] The "bad commit" already merged to `main` (the unindexed
      `users.email` query). The repo's `main` HEAD should currently include
      the file `app/api/users.py` with a `WHERE email = ?` SELECT and **no**
      `idx_users_email` index in `db/migrations/`.
- [ ] CodePipeline / GitHub Actions has finished deploying that commit to
      the EKS cluster (verify the running pod's image SHA matches the latest
      ECR tag)
- [ ] CloudWatch alarm `bjs-web-p99-latency-high` is in `OK` and the metric
      currently sits at the healthy ~50ms baseline
- [ ] `bjs-web.yingchu.cloud` resolves to the internal ALB
      `internal-k8s-bjsweb-todoapi-c36eae0a01-108833280.cn-north-1.elb.amazonaws.com.cn`
      from the host that will run `inject-L4` (DNS via Tencent DNSPod)
- [ ] One of `hey`, `ab`, or python with `aiohttp` is installed for the
      load generator

```bash
unset AWS_PROFILE AWS_REGION

aws --profile ychchen-bjs1 --region cn-north-1 \
  cloudwatch describe-alarms --alarm-names bjs-web-p99-latency-high \
  --query 'MetricAlarms[0].StateValue' --output text
# expect: OK
```

## Inject

Use L4 to drive sustained 50 RPS on the unindexed search endpoint. The
load triggers the alarm within a few minutes. The "bad commit" itself is
already on `main` from the demo setup — we are not re-pushing it here.

```bash
unset AWS_PROFILE AWS_REGION
cd /Users/ychchen/warren_ws/aws-devops-agent-external-mcp/demo-cases/faults
./inject-L4-unindexed-query-load.sh
```

The script:
1. Picks the best available load tool (`hey` > `ab` > python aiohttp).
2. Records its PID to `L4-load.pid`.
3. Runs for `L4_DURATION` (default `5m`) at `L4_RPS` (default `50`).
4. Targets `POST $BJS_WEB_URL/api/users/search` with `{"email":"x@y.com"}`.

Wait ~2-4 minutes. Verify the alarm went red:

```bash
aws --profile ychchen-bjs1 --region cn-north-1 \
  cloudwatch describe-alarms --alarm-names bjs-web-p99-latency-high \
  --query 'MetricAlarms[0].StateValue' --output text
# expect: ALARM
```

## Trigger / Query

Type the following query into Agent Space (single-line):

```
Why has bjs-web p99 latency spiked over the last 10 minutes? Look at metrics, recent deploys to bjs-todo-api, and the database — give me a complete RCA.
```

(Or the shorter variant: `为什么过去 10 分钟 bjs-web 延迟飙升？`)

## Expected Agent Behavior

- Calls CloudWatch via our cn-north-1 MCP, identifies the **anomaly start
  time T** on the p99 metric.
- Calls the GitHub / CodePipeline integration, finds the **last deploy
  completion time T'** to `bjs-web` namespace (from the CodePipeline run or
  `kubectl rollout history`).
- **Explicitly states the time delta** in seconds, e.g.
  `metric anomaly T = 2026-05-14T07:23:42Z, last deploy completed
  T' = 2026-05-14T07:20:55Z, delta = 167s`.
- Pulls the diff for the deploy's commit. Highlights the new `WHERE email = ?`
  SELECT introduced in `app/api/users.py`.
- Calls RDS (Performance Insights or `pg_stat_statements` via our MCP).
  Surfaces a top-N query with high mean execution time and `Seq Scan on users`.
- Confirms `users.email` has **no index**.
- RCA report contains:
  - Concrete commit hash + `file:line`
  - The SQL fix: `CREATE INDEX idx_users_email ON users(email);`
  - The deploy-time correlation as the lead "smoking gun"

## Acceptance Criteria

- [ ] Agent output **explicitly contains a time-delta expression** ("X seconds"
      or "X minutes" between deploy and metric anomaly)
- [ ] Output names a **specific commit hash** and `file:line` for the new
      query (e.g. `app/api/users.py:42`)
- [ ] Output recommends the SQL `CREATE INDEX idx_users_email ON users(email);`
- [ ] Agent invoked **at least three** distinct tool/data sources: CloudWatch,
      GitHub (or CodePipeline), and RDS / Performance Insights
- [ ] Lead conclusion is the unindexed query — **not** a generic
      "scale the cluster" answer

## Screenshots to capture

Save under `blog/screenshots/`:

1. `case-2-p99-alarm-graph.png` — CloudWatch metric graph with the spike
   clearly visible, threshold annotated
2. `case-2-agent-timeline.png` — Agent Space timeline view showing
   parallel investigation of metrics + GitHub + RDS
3. `case-2-time-delta-callout.png` — Zoom-in on the agent's
   "metric T vs deploy T' delta = N seconds" sentence
4. `case-2-commit-diff-reference.png` — Agent's RCA referencing the bad
   commit hash with the offending file:line
5. `case-2-rca-report-full.png` — Full RCA markdown including the
   `CREATE INDEX` recommendation

## Recover

```bash
unset AWS_PROFILE AWS_REGION
cd /Users/ychchen/warren_ws/aws-devops-agent-external-mcp/demo-cases/faults
./recover-L4-unindexed-query-load.sh
```

This kills the background load generator and removes the pidfile. The p99
metric returns to baseline within a few minutes; the alarm transitions back
to `OK`.

> **Important**: do **not** apply the `CREATE INDEX` fix here. **C7** picks
> up where C2 leaves off and uses the same RCA to drive a coding agent
> (Claude Code) to commit the fix as a PR. Applying it manually would erase
> the C7 demo. If you must reset, drop the index again before C7.

## Common pitfalls

- **Agent guesses without correlating** — if it answers "looks like high
  load, scale the deployment" without referencing GitHub or RDS, GitHub is
  not connected to the agent or our MCP cannot reach Performance Insights.
  Verify GitHub integration in Agent Space → Integrations → GitHub. Verify
  the MCP can reach RDS by asking the agent a separate baseline question
  ("describe the bjs-todo-db RDS instance").
- **DNS / Host header mismatch** — the ingress only matches host
  `bjs-web.yingchu.cloud`. If the load generator's URL is the raw ALB DNS
  with no `Host:` header, requests 404 and the metric never moves. The L4
  script defaults to `https://bjs-web.yingchu.cloud` to avoid this. Verify
  the URL works from your shell first.
- **Anomaly window too narrow** — CloudWatch p99 needs ~1-2 datapoints over
  threshold to flip the alarm. If the load only ran 60s the alarm may not
  fire and the agent has no anchor. Run the load for at least 3 minutes
  before asking the question.

## Notes for blog write-up

This is the WGU MTTR-77%-reduction case in spirit: the agent does
**second-level time anchoring** between two unrelated systems (CloudWatch
metrics + GitHub commits) without any pre-built correlation rule. The
"smoking gun" sentence — *"metric anomaly is 167 seconds after deploy
completion"* — is the screenshot worth the whole blog post.

For China readers, the additional point is that **the agent itself is not
in `cn-north-1`**: GitHub.com is global, CodePipeline is in `cn-north-1`
(or wherever the pipeline lives), CloudWatch is in `cn-north-1`, and our
MCP bridges the partition. The agent does not know — or care — which side
of the partition each piece of evidence comes from.
