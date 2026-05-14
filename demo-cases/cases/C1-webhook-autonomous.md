# C1 — Webhook Autonomous Investigation

> Design reference: `../../docs/superpowers/specs/2026-05-13-china-region-10-wow-cases-design.md` § 2 Case 1

## TL;DR

A bad image tag is rolled to the EKS `todo-api` deployment, pods enter
`ImagePullBackOff`, the `bjs-web-pod-not-ready` CloudWatch alarm fires, our
SNS-to-DevOps-Agent **bridge Lambda** signs an HMAC payload and POSTs the
incident to the agent's webhook. The DevOps Agent then runs the full
**Triage → RCA → Mitigation** pipeline autonomously and posts the three reports
into Slack — with **zero human prompt**.

This is the headline "agent does it for me" case and the only practical way to
get this flow to work in a China region today (DevOps Agent does not natively
support `cn-*` partitions; the bridge crosses the partition for us).

## Prereqs

Before running this case, verify:

- [ ] Agent Space wired and reachable from the user's browser
- [ ] DevOps Agent **Webhook URL + HMAC secret** generated in console and stored in
      bjs1 SSM as `/devops-agent/webhook-url` and `/devops-agent/webhook-secret`
      (per `demo-cases/SETUP-AGENT-SPACE.md` § 2)
- [ ] GitHub `bjs-todo-api` repo connected to Agent Space (used for deploy-time
      correlation in the RCA step)
- [ ] Slack workspace connected; channel `#bjs-web-incidents` invited the agent
- [ ] EKS deployment currently healthy at `v1.2.3` baseline
      (`kubectl --context bjs1 -n bjs-web get pods` shows `3/3 Running`)
- [ ] CloudWatch alarm `bjs-web-pod-not-ready` is in state `OK` before injecting
- [ ] Webhook bridge Lambda `devops-agent-bridge-bjs1` recent invocation has no
      recent errors in CloudWatch logs

```bash
# Environment quirk — ALWAYS run this before any aws / kubectl command in this case.
# AWS_PROFILE=claude-code-DO-NOT-DELETE in the shell env will override --profile and
# the script will silently target the wrong account.
unset AWS_PROFILE AWS_REGION

# Pre-flight verifications
aws --profile ychchen-bjs1 --region cn-north-1 \
  cloudwatch describe-alarms --alarm-names bjs-web-pod-not-ready \
  --query 'MetricAlarms[0].StateValue' --output text
# expect: OK

aws --profile ychchen-bjs1 --region cn-north-1 \
  ssm get-parameter --name /devops-agent/webhook-url --query 'Parameter.Value' --output text
# expect: a real https://... URL, NOT the placeholder

kubectl --context bjs1 -n bjs-web get pods
# expect: 3 pods Running, all on image bjs-todo-api:v1.2.3
```

## Inject

Use the prepared L6 script. It rolls the deployment to a non-existent tag,
which causes `ImagePullBackOff`, which causes the alarm to flip to `ALARM`
within ~2 minutes.

```bash
unset AWS_PROFILE AWS_REGION
cd /Users/ychchen/warren_ws/aws-devops-agent-external-mcp/demo-cases/faults
./inject-L6-pod-imagepullbackoff.sh
```

The script:
1. Records the current image to `L6-previous-image.txt` so recover can roll back.
2. Patches the deployment image tag to `bjs-todo-api:v1.2.4-DOES-NOT-EXIST`.
3. Watches pod status until at least one pod hits `ImagePullBackOff`.

Verify the symptom:

```bash
kubectl --context bjs1 -n bjs-web get pods -l app=todo-api
# expect: pods stuck in Init / ImagePullBackOff
kubectl --context bjs1 -n bjs-web describe pod -l app=todo-api | grep -A2 'Failed'
```

## Trigger / Query

**No human query.** Wait — the webhook will fire automatically.

Verification trail (in order, ~2-4 minutes total):

1. **Alarm fires**:
   ```bash
   aws --profile ychchen-bjs1 --region cn-north-1 \
     cloudwatch describe-alarms --alarm-names bjs-web-pod-not-ready \
     --query 'MetricAlarms[0].StateValue' --output text
   # expect: ALARM
   ```
2. **Bridge Lambda invoked**:
   ```bash
   aws --profile ychchen-bjs1 --region cn-north-1 \
     logs tail /aws/lambda/devops-agent-bridge-bjs1 --since 10m
   # expect: lines like "Posted incident <id> to webhook, status 200"
   ```
3. **Slack channel `#bjs-web-incidents`** receives 3 agent messages:
   - Triage Card (within ~1 min of alarm)
   - RCA Report (within ~3-5 min)
   - Mitigation Plan (within ~5-7 min)

## Expected Agent Behavior

- Webhook receives the incident; **Incident Triage** agent type starts
  automatically.
- Triage Card identifies the symptom as `k8s pod startup failure` and routes
  to the **RCA** agent type.
- RCA agent calls our MCP server → `kubectl describe pod` →  sees the
  `ImagePullBackOff` error message verbatim.
- RCA agent reads the deployment history (`kubectl rollout history`) and / or
  the GitHub `bjs-todo-api` repo timeline → notes the recent `set image` event
  ~5 minutes before the alarm.
- **Mitigation** agent emits a 4-field plan:
  - **Action**: `kubectl rollout undo deployment/todo-api -n bjs-web`
  - **Pattern**: B (rollback to last known-good revision)
  - **Approval contract**: prompt requesting human "approve" before applying
  - **Rollback**: re-apply the bad tag (rarely used, included for completeness)
- All three messages posted to `#bjs-web-incidents` Slack channel via the
  agent's Slack integration. The user did not type anything.

## Acceptance Criteria

- [ ] Slack channel received **at least 3 agent messages** (Triage Card,
      RCA Report, Mitigation Plan)
- [ ] RCA report references **either** a real `kubectl` operation timestamp
      **or** a GitHub commit/deploy event time
- [ ] Mitigation plan contains an explicit approval-contract prompt
      ("Reply approve to apply this remediation" or equivalent)
- [ ] **End-to-end time from alarm `ALARM` state → mitigation message in Slack
      is ≤ 8 minutes**
- [ ] **No human typed any query** — the entire flow was webhook-driven
- [ ] Bridge Lambda CloudWatch logs show `status 200` (or 2xx) on POST to webhook

## Screenshots to capture

Save under `blog/screenshots/`:

1. `case-1-alarm-state-alarm.png` — CloudWatch alarm `bjs-web-pod-not-ready`
   in `ALARM` state, with the metric graph showing the threshold breach
2. `case-1-bridge-lambda-logs.png` — `/aws/lambda/devops-agent-bridge-bjs1`
   tail showing successful POST to webhook
3. `case-1-slack-triage-card.png` — Slack message: Triage Card from agent
4. `case-1-slack-rca-report.png` — Slack message: RCA Report (with the
   `ImagePullBackOff` and the deploy-time correlation visible)
5. `case-1-slack-mitigation-plan.png` — Slack message: Mitigation Plan with
   the approval contract
6. `case-1-agent-investigation-timeline.png` — Agent Space console showing the
   Triage → RCA → Mitigation timeline / tools-used panel

## Recover

```bash
unset AWS_PROFILE AWS_REGION
cd /Users/ychchen/warren_ws/aws-devops-agent-external-mcp/demo-cases/faults
./recover-L6-pod-imagepullbackoff.sh
```

The recover script reads `L6-previous-image.txt` and rolls the deployment
back to the prior known-good image (defaults to `bjs-todo-api:v1.2.3`).
Verify recovery:

```bash
kubectl --context bjs1 -n bjs-web get pods -l app=todo-api
# expect: 3/3 Running on v1.2.3
aws --profile ychchen-bjs1 --region cn-north-1 \
  cloudwatch describe-alarms --alarm-names bjs-web-pod-not-ready \
  --query 'MetricAlarms[0].StateValue' --output text
# expect: OK (within ~2 minutes)
```

If you also want to clear the agent's incident state, use the agent console
to mark the incident as **Resolved** before running the next case — otherwise
follow-up correlation in C2/C9 may pick up stale context.

## Common pitfalls

- **`AWS_PROFILE=claude-code-DO-NOT-DELETE` from the shell env** silently
  overrides `--profile` and the inject script lands in the WRONG account.
  Always start with `unset AWS_PROFILE AWS_REGION` — every script does this
  on its own first line, but if you call `aws` interactively to verify state
  you must do it too.
- **Webhook URL still set to placeholder** in SSM. The bridge Lambda will
  fail with `Bad Request` and the agent never receives the incident. Verify
  the SSM value is a real URL before injecting.
- **Slack integration not configured for `#bjs-web-incidents`**. The agent
  runs the investigation but has nowhere to post — you'll see results in
  Agent Space console only, breaking the "autonomous + Slack" headline.
  Fix in Agent Space → Integrations → Slack before running.

## Notes for blog write-up

This is the strongest opening shot for the China-region story:

- **The native DevOps Agent does not support `cn-*` partitions** — there is
  no path for a CloudWatch alarm in cn-north-1 to reach the agent's webhook
  out of the box.
- This case shows the **end-to-end alarm-to-mitigation flow working in
  Beijing** by inserting a tiny bridge Lambda that signs the alarm with HMAC
  and forwards it to our us-east-1 EKS-hosted MCP + agent.
- Lead with the timer: "T+0 alarm fires, T+5min agent posts a 4-field
  mitigation plan to Slack, **no human typed anything**".
- The screenshot of `bridge-lambda-logs` next to `slack-mitigation-plan`
  is the visual punch — two systems on opposite sides of the GFW handing
  the incident off in seconds.
