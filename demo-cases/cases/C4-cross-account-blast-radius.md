# C4 — Cross-Account Blast Radius (RCA Axis 4 in production)

> Design reference: `../../docs/superpowers/specs/2026-05-13-china-region-10-wow-cases-design.md` § 2 Case 4

## TL;DR

The bjs1 ALB starts emitting 5xx after we corrupt the target-group health
check (interval bumped from 30s → 240s, then a pod is killed; it takes the
ALB 4 minutes to evict the bad target, during which clients see errors).
We ask the agent: **"is this only bjs1 or is china also affected?"** —
and watch it call **both accounts in parallel**, confirm china is fine,
and emit an explicit "blast radius: account-scoped, NOT
platform-wide" verdict in the standard 4-axis RCA report. This is the
real, working version of RCA Axis 4.

## Prereqs

- [ ] Agent Space wired and authenticated; **both** the bjs1 and china
      MCP routes are working (verify by asking the agent two
      account-specific baseline queries first)
- [ ] `china-region-multi-account-routing` skill uploaded to Agent Space
      (drives parallel cross-account tool calls)
- [ ] `china-incident-rca` skill uploaded (provides the 4-axis report
      template, with Axis 4 = blast radius)
- [ ] EKS `todo-api` deployment healthy at baseline; ALB target group
      healthy with `health-check-interval-seconds = 30`
- [ ] CloudWatch alarm `bjs-web-alb-5xx-rate-high` is in `OK`
- [ ] china ECS / ALB are at baseline as well (so the cross-check has
      something clean to compare against)

```bash
unset AWS_PROFILE AWS_REGION
aws --profile ychchen-bjs1 --region cn-north-1 \
  cloudwatch describe-alarms --alarm-names bjs-web-alb-5xx-rate-high \
  --query 'MetricAlarms[0].StateValue' --output text
# expect: OK
```

## Inject

```bash
unset AWS_PROFILE AWS_REGION
cd /Users/ychchen/warren_ws/aws-devops-agent-external-mcp/demo-cases/faults
./inject-L8-alb-healthcheck-240s.sh
```

What it does:
1. Discovers (or reads from `L8-target-group-arn.txt`) the target-group ARN
   for the `bjs-web-alb` ALB.
2. Modifies `health-check-interval-seconds` from 30 → 240. Caches the ARN
   so recover can find it.
3. Deletes one `todo-api` pod with `kubectl delete pod`. The replicaset
   immediately schedules a replacement, but the **old pod's IP** stays
   "healthy" in the ALB target group for ~4 minutes because of the slowed
   health check. Clients hitting that target see 5xx until eviction.
4. Waits for the alarm `bjs-web-alb-5xx-rate-high` to flip to `ALARM`.

Verify:

```bash
kubectl --context bjs1 -n bjs-web get pods -l app=todo-api
# expect: one pod recently created, others Running

aws --profile ychchen-bjs1 --region cn-north-1 \
  elbv2 describe-target-health \
    --target-group-arn $(cat /Users/ychchen/warren_ws/aws-devops-agent-external-mcp/demo-cases/faults/L8-target-group-arn.txt)
# expect: at least one target Unhealthy or draining
```

## Trigger / Query

Type into Agent Space:

```
The bjs1 ALB is throwing 5xx errors. Is this only bjs1, or is the china account also impacted? Give me a full 4-axis RCA including blast radius.
```

(Or shorter: `bjs1 ALB 5xx 升高，是不是 china 账号也出问题了`)

## Expected Agent Behavior

- Activates the `china-incident-rca` skill (4-axis report template).
- Activates the `china-region-multi-account-routing` skill (so it knows
  to dispatch in **both** account-scoped MCP routes simultaneously).
- **Axis 1 (What)**: bjs1 ALB 5xx rate elevated; target health degraded.
- **Axis 2 (Why)**: target-group `health-check-interval-seconds = 240`
  combined with pod termination; old IP not evicted until ~4 minutes
  after pod death.
- **Axis 3 (When)**: timeline — pod deletion event → first 5xx → alarm
  flip — all within a 4-minute window.
- **Axis 4 (Blast Radius)** — the headline:
  - Calls china account in parallel (CloudWatch ALB metrics, ECS service
    health). Reports **clean**.
  - Verdict: *"Blast radius: scoped to bjs1 account only. NOT a
    platform-wide issue."*
- **Fix recommendation**: revert `health-check-interval-seconds` to 30.

The Agent Space "Tools used" panel should show calls to **both** the bjs1
and china MCP endpoints, ideally close together in time (parallel
dispatch, not sequential).

## Acceptance Criteria

- [ ] Agent invokes **both** account MCPs (bjs1 + china) — visible in the
      tools panel as ≥ 2 distinct profile/region tool calls
- [ ] RCA report contains a clearly labelled **Axis 4 / Blast Radius**
      section
- [ ] Verdict is explicitly `account-scoped` (or "scoped to bjs1 only" /
      "NOT platform-wide" — the wording must rule out china)
- [ ] Fix recommendation names the specific config knob:
      `health-check-interval-seconds` (or equivalent ALB target-group
      health-check setting)
- [ ] Total time from query to final report ≤ 6 minutes

## Screenshots to capture

Save under `blog/screenshots/`:

1. `case-4-tools-panel-two-accounts.png` — Tools-used panel showing
   parallel calls into bjs1 and china (this is the "real cross-account"
   evidence)
2. `case-4-rca-axis4-blast-radius.png` — Zoom-in on the Axis 4 paragraph
   declaring account-scoped
3. `case-4-bjs1-vs-china-metrics.png` — Side-by-side ALB 5xx rate /
   target health: bjs1 spiking vs china flat
4. `case-4-fix-recommendation.png` — The agent's specific knob to revert
   (`health-check-interval-seconds: 30`)
5. `case-4-tg-config-before-after.png` (optional) — `aws elbv2
   describe-target-groups` showing 240 before, 30 after recover

## Recover

```bash
unset AWS_PROFILE AWS_REGION
cd /Users/ychchen/warren_ws/aws-devops-agent-external-mcp/demo-cases/faults
./recover-L8-alb-healthcheck-240s.sh
```

The recover script:
1. Reads `L8-target-group-arn.txt` (or rediscovers if missing).
2. Modifies `health-check-interval-seconds` back to 30.
3. Waits for all targets healthy and for the alarm to return to `OK`.

Verify:

```bash
aws --profile ychchen-bjs1 --region cn-north-1 \
  elbv2 describe-target-groups \
    --target-group-arns $(cat /Users/ychchen/warren_ws/aws-devops-agent-external-mcp/demo-cases/faults/L8-target-group-arn.txt) \
    --query 'TargetGroups[0].HealthCheckIntervalSeconds' --output text
# expect: 30
```

## Common pitfalls

- **Agent only checks bjs1** — the cross-account dispatch comes from the
  routing skill. If the skill isn't uploaded or the picker didn't fire,
  you'll get a normal single-account RCA. Verify via the agent's
  tools/skills activation log; if missing, re-upload the skill (zip is at
  `skills/china-region-multi-account-routing.zip`) and re-ask.
- **MCP route confusion** — the agent might try to use a `--profile
  ychchen-china` style call against the bjs1 MCP endpoint. Each account's
  MCP must be reachable via its own route in our chart deployment
  (`aws-cn` and `aws-cn-2` releases). Confirm both routes work by asking
  baseline queries first.
- **Alarm flapping on recover** — when you set health-check-interval back
  to 30, the alarm may briefly stay `ALARM` for one more datapoint before
  clearing. Wait 2-3 minutes before declaring recovery failed.

## Notes for blog write-up

This is the case that turns the v1 "compare two VPCs" parlor trick into
a real production RCA pattern. The screenshot to lead with is the **tools
panel showing two accounts in parallel** — most readers have never seen
an agent fan out to two AWS accounts on a single question.

Pull-quote candidate for the blog:

> *"In native DevOps Agent today, the answer to 'is china also impacted?'
> is silence — there's no `cn-*` partition support. Here, the agent
> answers in 30 seconds across both accounts and labels the blast radius
> in writing."*
