# C5 — Agent Gets It Wrong → Skill Saves the Day (cn-partition-arn-routing)

> Design reference: `../../docs/superpowers/specs/2026-05-13-china-region-10-wow-cases-design.md` § 2 Case 5

## TL;DR

This is the **two-pass demo**. We deliberately leave a China-region
partition bug in an IAM trust policy: the role's trust block writes
`arn:aws:iam::*:role/...` instead of `arn:aws-cn:iam::*:role/...`. Lambda
fires `sts:AssumeRole` and gets `AccessDenied`. Without the
**`cn-partition-arn-routing`** skill, the agent diagnoses it as a
generic IAM permissions problem and recommends the **wrong fix**. We then
upload the skill, re-run the same query, and the agent now correctly
identifies the partition mismatch and suggests rewriting the ARN to
`aws-cn`. This is the strongest *Continuous Learning* case we have —
the same agent, same data, same question — but a 50-line skill changes
the answer from wrong to right.

## Prereqs

- [ ] Agent Space wired and authenticated
- [ ] **For Pass 1 (the failing pass)** — confirm the
      `cn-partition-arn-routing` skill is **NOT** active in Agent Space
      (delete it from the skills list if it was uploaded earlier; or
      run this case in a fresh agent space)
- [ ] **For Pass 2** — have the skill zip ready locally:
      `/Users/ychchen/warren_ws/aws-devops-agent-external-mcp/skills/cn-partition-arn-routing.zip`
- [ ] IAM role `bjs-cross-partition-test-role` exists in bjs1 with the
      *broken* trust policy already baked into terraform (the role's
      trust block is the demo artifact)
- [ ] CloudTrail in bjs1 is enabled (so the inject script's `AccessDenied`
      event is visible to the agent)

```bash
unset AWS_PROFILE AWS_REGION
aws --profile ychchen-bjs1 --region cn-north-1 \
  iam get-role --role-name bjs-cross-partition-test-role \
  --query 'Role.AssumeRolePolicyDocument' --output json
# expect: trust policy contains "arn:aws:iam::*:role/..." (the BUG)
```

## Inject

```bash
unset AWS_PROFILE AWS_REGION
cd /Users/ychchen/warren_ws/aws-devops-agent-external-mcp/demo-cases/faults
./inject-L7-cross-partition-trust.sh
```

What it does:
1. Creates (or upserts) a probe Lambda in bjs1 that calls
   `sts:AssumeRole` against the broken role's `arn:aws-cn:` ARN.
2. Triggers the Lambda once. The call is denied because the trust policy
   references `arn:aws:` which doesn't match the `arn:aws-cn:` principal.
3. CloudTrail records the `AssumeRole` failure with `errorCode =
   AccessDenied`. CloudWatch logs for the probe Lambda also show the
   denial. This is the "incident" the agent will investigate.

(There is no CloudWatch alarm in this case — we drive the agent
manually with a query, twice.)

Verify the failure landed in CloudTrail:

```bash
aws --profile ychchen-bjs1 --region cn-north-1 \
  cloudtrail lookup-events \
    --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRole \
    --max-results 5 \
    --query 'Events[?contains(CloudTrailEvent, `AccessDenied`) || contains(CloudTrailEvent, `bjs-cross-partition-test-role`)].EventTime' \
    --output table
```

## Trigger / Query

This is a **two-pass** case. The query is **the same both times**:

```
A Lambda in bjs1 is failing with AccessDenied when calling sts:AssumeRole on bjs-cross-partition-test-role. Investigate and tell me how to fix the trust policy.
```

### Pass 1 — without the skill

1. Confirm `cn-partition-arn-routing` is not in Agent Space → Skills.
2. Type the query above.
3. **Capture the agent's response in full.** Expected (wrong) answer:
   - The agent finds the `AccessDenied` log line and the trust policy.
   - It misdiagnoses: suggests adding `sts:AssumeRoleWithSAML` permission,
     or relaxing the trust principal to a wildcard, or attaching another
     policy.
   - It does **not** notice the partition prefix mismatch.
4. **Do not act on the wrong fix.** Just save the screenshot.

### Pass 2 — upload the skill, re-ask the same query

1. In Agent Space → Skills → Upload, attach the zip:
   `/Users/ychchen/warren_ws/aws-devops-agent-external-mcp/skills/cn-partition-arn-routing.zip`
2. Confirm the skill appears as enabled.
3. Re-run the **same** query verbatim.
4. The agent now correctly identifies the issue and suggests rewriting
   `arn:aws:iam::*:role/...` to `arn:aws-cn:iam::*:role/...`.

## Expected Agent Behavior

**Pass 1 (no skill)** — wrong:
- Agent reads CloudTrail / Lambda logs and confirms `AccessDenied`.
- Reads the trust policy via `iam:GetRole`.
- Diagnoses as a generic IAM problem (missing permission, missing
  principal, etc.).
- Recommends an incorrect fix that does not mention partition prefixes.

**Pass 2 (with skill)** — right:
- Skill picker (visible in the agent activation log) selects
  `cn-partition-arn-routing` because the question mentions IAM in a `cn-*`
  region.
- Agent reads the same trust policy.
- This time **explicitly identifies** that the trust policy uses
  `arn:aws:` while the principal is in `aws-cn` partition. Quotes the rule:
  *"In cn-north-1 / cn-northwest-1 the partition is `aws-cn`, not `aws`."*
- Recommends rewriting the trust ARN. Provides a concrete patched trust
  policy snippet.

## Acceptance Criteria

- [ ] **Pass 1** output is captured with the **wrong recommendation**
      visible in screenshot — proof of the agent's natural blind spot
- [ ] **Pass 2** uses the **same query verbatim** as Pass 1
- [ ] Pass 2 output explicitly mentions `aws-cn` partition and the ARN
      rewrite
- [ ] The skill activation log shows `cn-partition-arn-routing` was
      picked by the picker in Pass 2 (and **not** in Pass 1)
- [ ] Side-by-side screenshot composed showing Pass 1 wrong vs Pass 2 right

## Screenshots to capture

Save under `blog/screenshots/`:

1. `case-5-pass1-wrong-diagnosis.png` — full Pass 1 agent output with
   the wrong fix highlighted
2. `case-5-pass1-skill-list-empty.png` — Agent Space skills tab showing
   `cn-partition-arn-routing` is NOT present
3. `case-5-skill-uploading.png` — uploading
   `cn-partition-arn-routing.zip` in Agent Space (skills list with
   the skill newly added)
4. `case-5-pass2-correct-diagnosis.png` — full Pass 2 agent output with
   the partition-mismatch explanation
5. `case-5-pass2-picker-activation.png` — agent activation log
   showing `cn-partition-arn-routing` selected
6. `case-5-side-by-side.png` — manually composed side-by-side of the
   wrong-fix paragraph vs the correct-fix paragraph (the headline shot
   for the blog)

## Recover

```bash
unset AWS_PROFILE AWS_REGION
cd /Users/ychchen/warren_ws/aws-devops-agent-external-mcp/demo-cases/faults
./recover-L7-cross-partition-trust.sh
```

The recover script removes the probe Lambda + its execution role.
**It does not fix the IAM trust policy** — the broken role
`bjs-cross-partition-test-role` is the persistent demo artifact, owned
by terraform. To remove the role itself, use `terraform destroy` in
`infra/bjs1-stack`.

After recovery, **decide whether to keep the skill** in Agent Space:
- For repeat demos: leave it. Future cases will benefit.
- For a clean-slate walk-through: remove it again so Pass 1 stays
  reproducible.

## Common pitfalls

- **Pass 1 secretly uses the skill** — the most common failure mode is
  forgetting that the skill was uploaded in a previous demo. The agent
  then "knows" the right answer in Pass 1 and the whole case collapses.
  Always verify the Agent Space skills list is empty of
  `cn-partition-arn-routing` before Pass 1.
- **Probe Lambda IAM eventual consistency** — first run sleeps 10s after
  creating the execution role; if you cancelled the script and re-ran it
  without that sleep, the call may fail for a different reason
  (`PendingRole`) and confuse the agent. Let the script run to completion.
- **Same-query enforcement** — for the demo to be persuasive, Pass 1 and
  Pass 2 must use the **identical** query string. Copy-paste from this
  playbook; do not re-type from memory.

## Notes for blog write-up

This is the **headline argument for custom skills** in the China-region
context. AWS partition knowledge (`aws` vs `aws-cn` vs `aws-us-gov`) is
exactly the kind of domain knowledge a generic foundation model gets
wrong because it's underrepresented in training data. A 50-line skill
fixes it permanently.

Suggested blog framing:

> *"The agent isn't dumb — it's untrained for `cn-*`. The whole point of
> custom skills is that you can teach it your local truth without
> retraining the model. Same agent, same incident, same question: one
> upload turns 'wrong' into 'right'."*

Lead the blog section with the **side-by-side side-by-side screenshot**.
That single image carries the entire continuous-learning story.
