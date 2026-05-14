# C6 — Predictive Ops Backlog (Evaluation agent type)

> Design reference: `../../docs/superpowers/specs/2026-05-13-china-region-10-wow-cases-design.md` § 2 Case 6

## TL;DR

Run the **Evaluation agent type** with the
`china-account-prevention-checks` skill. The agent sweeps both accounts
across 9 prevention dimensions and emits an **ops backlog** of risks
prioritized by *time-to-incident*: 🔴 immediate, 🟠 within 30 days,
🟡 within 60-90 days. Each finding has a business-impact tag. This is
**predictive ops** — the agent doesn't wait for an alarm; it tells you
what *will* break.

## Prereqs

- [ ] Agent Space wired and authenticated
- [ ] **`china-account-prevention-checks`** skill uploaded (zip at
      `skills/china-account-prevention-checks.zip`)
- [ ] Evaluation agent type available in Agent Space (or fallback: ask the
      Investigation agent type to run the skill on demand — works for the
      demo, less impressive but functional)
- [ ] L1 RDS-no-multi-AZ fault is **active** (it should be — the demo's
      baseline state has `bjs-todo-db` set to single-AZ deliberately)
- [ ] L3 IAM-key-65d-old fault is **active** (the inject script creates
      the simulated metadata file; see "L3 backdating limitation" below)
- [ ] Both account profiles authenticated and the prevention skill can
      reach IAM, RDS, EC2, ACM, Lambda, etc. via our MCP

```bash
unset AWS_PROFILE AWS_REGION

# Verify L1 baseline
aws --profile ychchen-bjs1 --region cn-north-1 \
  rds describe-db-instances --db-instance-identifier bjs-todo-db \
  --query 'DBInstances[0].MultiAZ' --output text
# expect: False

# Verify L3 metadata file (after inject-L3 has run)
ls -la /Users/ychchen/warren_ws/aws-devops-agent-external-mcp/demo-cases/faults/L3-simulated-metadata.json
# expect: file exists, contains simulated_create_date 65 days in the past
```

## Inject

L1 is part of baseline (no inject needed). For L3, run the inject script
to create the simulated-65-day-old IAM key:

```bash
unset AWS_PROFILE AWS_REGION
cd /Users/ychchen/warren_ws/aws-devops-agent-external-mcp/demo-cases/faults
./inject-L3-iam-key-old.sh
```

What it does:
1. Creates IAM user `bjs-demo-rotation-test` in bjs1 (or reuses if
   already present).
2. Creates an access key pair for that user.
3. Writes `L3-simulated-metadata.json` recording
   `simulated_create_date = now - 65 days` (the prevention skill is
   instructed to read this file as the canonical timestamp because AWS
   does not allow setting `CreateDate` on access keys).

**No CloudWatch alarm fires** for this case — it's an evaluation, not an
incident. The agent is asked to assess proactively.

## Trigger / Query

In Agent Space, switch to the **Evaluation agent type** (or open a new
session if Evaluation is the only agent type). Type:

```
Run weekly prevention checks across both China-region accounts. Generate an ops backlog with severity, time-to-incident, and business impact for each finding.
```

(Or shorter: `执行 weekly prevention check，生成 ops backlog`)

## Expected Agent Behavior

- Activates the `china-account-prevention-checks` skill.
- Runs 9 prevention dimensions across both accounts (expect, at minimum:
  RDS Multi-AZ, IAM key age, ASG min/desired, ACM cert expiry, Lambda
  runtime deprecation, S3 public access, CloudTrail enabled, RDS backup
  retention, security group 0.0.0.0/0).
- Emits a markdown **ops backlog** structured by severity buckets:
  - 🔴 **IMMEDIATE (<14 days)**: anything urgent
  - 🟠 **30 days**: must include
    - `bjs-todo-db is single-AZ` (L1) — high impact, ~30-day soft target
    - IAM access key on `bjs-demo-rotation-test` is **65 days old**, must
      rotate within **25 days** (90-day hard policy)
  - 🟡 **60-90 days**: ASG min=desired=1 single-instance risk; ACM cert
    days-to-expiry; Lambda Python 3.7 runtime EOL; etc.
- Each finding has tags: `severity: high|medium|low`,
  `business_impact: high|medium|low`, `account: bjs1|china`,
  `recommended_action: ...`.

## Acceptance Criteria

- [ ] Output contains **at least 5 distinct findings** drawn from the
      live infrastructure (not invented, not template-stuffed)
- [ ] Each finding labeled with both `severity` and `business_impact`
- [ ] Output formatted as a usable markdown ops backlog (priority-sorted
      list with action items, not free-form prose)
- [ ] **L1 (RDS single-AZ)** is identified — must appear in 🟠 30-day
      bucket or hotter
- [ ] **L3 (IAM key 65 days old)** is identified — must appear with
      "rotate within 25 days" or equivalent precise countdown
- [ ] Findings span **both accounts** (at least one finding per account)

## Screenshots to capture

Save under `blog/screenshots/`:

1. `case-6-evaluation-timeline.png` — Agent Space evaluation run
   timeline showing all 9 dimensions + both accounts being evaluated
2. `case-6-ops-backlog-full.png` — full ops backlog markdown rendered
   in the agent UI
3. `case-6-severity-buckets.png` — close-up showing the 🔴/🟠/🟡 bucket
   structure
4. `case-6-l1-rds-finding.png` — close-up of the RDS Multi-AZ finding
   with the 30-day count-down
5. `case-6-l3-iam-key-finding.png` — close-up of the IAM key finding
   with `rotate within 25 days`
6. `case-6-business-impact-tags.png` — at least one finding showing
   the `business_impact: high` tag

## Recover

L1 is part of baseline — **do not** "recover" it (the C6 demo needs it
to keep working). If you accidentally fixed it, run:

```bash
unset AWS_PROFILE AWS_REGION
cd /Users/ychchen/warren_ws/aws-devops-agent-external-mcp/demo-cases/faults
./inject-L1-rds-no-multi-az.sh   # re-injects the baseline single-AZ
```

For L3 (cleanup before teardown):

```bash
cd /Users/ychchen/warren_ws/aws-devops-agent-external-mcp/demo-cases/faults
./recover-L3-iam-key-old.sh
# deletes the IAM user + all keys + the metadata file
```

## Common pitfalls

- **L3 backdating** — AWS does not allow setting `CreateDate` on access
  keys. The inject script creates the user + key NOW and writes
  `L3-simulated-metadata.json` with a synthetic
  `simulated_create_date = now - 65 days`. **The prevention skill prompt
  must explicitly read this file** and prefer it over IAM's actual
  `CreateDate`. If the skill version you uploaded doesn't include that
  shim, the agent will report the key as fresh (1 day old). Verify the
  skill source `skills/china-account-prevention-checks/SKILL.md` mentions
  the metadata file, or run the inject script 65+ days before the demo
  for real ageing.
- **Evaluation agent type unavailable** — some Agent Space tenants only
  expose Investigation. In that case, ask the Investigation agent the
  same query and explicitly mention the skill: *"Use
  `china-account-prevention-checks` to run a 9-dimension prevention
  sweep..."*. Output looks identical, just dispatched differently.
- **Wrong account scope** — if the agent only checks one account, the
  multi-account routing skill may be missing. Upload
  `china-region-multi-account-routing` (zip at
  `skills/china-region-multi-account-routing.zip`) before re-running.

## Notes for blog write-up

C6 is the **predictive** half of the story (paired with C10 which is the
cost predictive case). Native DevOps Agent has Evaluation agent type but
no `cn-*` partition support — meaning **no native way to run a weekly
prevention check on China-region accounts**. This case demonstrates that
once the bridge is in place, you not only get reactive RCA (C1-C5) but
also proactive risk assessment with concrete time-to-incident estimates.

Lead screenshot: the ops backlog with both **L1's 30-day countdown**
and **L3's 25-day key rotation deadline** visible in the same frame.
The reader's takeaway: *"the agent told me what's about to break, with
specific dates."*
