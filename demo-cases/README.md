# 10 WOW-Factor Demo Cases for AWS DevOps Agent in China Regions

Companion artifact to:
- Design doc: `docs/superpowers/specs/2026-05-13-china-region-10-wow-cases-design.md`
- Phase 2 deployment snapshot: `PHASE2-DEPLOYED.md`
- Manual Agent Space setup: `SETUP-AGENT-SPACE.md`

## Layout

```
demo-cases/
├── README.md              ← you are here
├── PHASE2-DEPLOYED.md     ← what's actually deployed right now
├── SETUP-AGENT-SPACE.md   ← console-only manual steps
├── infra/
│   ├── bjs1-stack/        terraform: cn-north-1 web app stack
│   ├── china-stack/       terraform: cn-northwest-1 data service stack
│   └── webhook-bridge/    terraform: SNS-to-DevOpsAgent bridge Lambda
│                          (deploys to both accounts via workspaces)
├── app/
│   ├── bjs-todo-api/      FastAPI todo app (the unindexed-query bug)
│   └── etl-worker/        ECS Fargate SQS-to-DDB worker
├── faults/                9 inject + 9 recover scripts (L1-L9)
└── cases/                 (Phase 4) per-case execution playbooks
```

## How the 10 cases map to faults

| Case | Theme | Faults used | Native vs Skill |
|---|---|---|---|
| C1 | Webhook autonomous investigation | L6 (EKS ImagePullBackOff) | native |
| C2 | Time-anchored deploy correlation | L4 (unindexed query) | native |
| C3 | Multi-hop topology RCA | L5 (DDB throttle + ECS OOM) | native |
| C4 | Cross-account blast radius | L8 (ALB health-check 240s) | skill (rca Axis 4) |
| C5 | Agent-gets-it-wrong → skill saves day | L7 (cross-partition trust) | **skill (cn-partition-arn-routing)** |
| C6 | Predictive ops backlog | L1 (RDS single-AZ), L3 (IAM key 65d) | skill (prevention) |
| C7 | Agent-ready spec → coding agent loop | continuation of L4 / C2 | native + Kiro |
| C8 | Topology-driven onboarding query | none (read-only) | native |
| C9 | 5-source multi-signal RCA | L4 + L9 (CPU limit too low) | native + rca skill |
| C10 | Cost anomaly → ops backlog | L2 (S3 public + ECS scale anomaly) | skill (cost-attribution) |

## Quick reference

```bash
# 0. Always run before any AWS command (the env-var quirk)
unset AWS_PROFILE AWS_REGION

# 1. Inject a single fault
demo-cases/faults/inject-L1-rds-no-multi-az.sh

# 2. Recover it
demo-cases/faults/recover-L1-rds-no-multi-az.sh

# 3. Inject all (with confirmation per fault)
demo-cases/faults/inject-all.sh

# 4. Inject all unattended (skip confirms)
demo-cases/faults/inject-all.sh --yes

# 5. Recover everything
demo-cases/faults/recover-all.sh
```

## Phase progression

- **Phase 1** ✅ artifacts written + validated
- **Phase 2** ✅ infrastructure deployed to both accounts (see PHASE2-DEPLOYED.md)
- **Phase 3** ⏳ Agent Space console steps (user, see SETUP-AGENT-SPACE.md)
- **Phase 4** ⏳ execute 10 cases, capture screenshots
- **Phase 5** ⏳ teardown via `terraform destroy` in both stacks + webhook-bridge workspaces

## Costs to date (estimated)

After Phase 1 + 2 deploy:
- bjs1 EKS control plane: ~¥4/day
- bjs1 1× t3.medium node: ~¥3/day
- bjs1 RDS PG db.t3.micro single-AZ: ~¥2/day
- bjs1 ALB: ~¥3/day
- china RDS MySQL db.t3.micro multi-AZ: ~¥4/day
- china ECS Fargate (1 task + cluster idle): ~¥1/day
- Other (S3, CW logs, SQS, Lambda, DDB on-demand, NAT-equivalent): ~¥3/day

Roughly **¥20/day** while idle. Phase 4 case execution adds DevOps Agent
investigation seconds (~¥0.04/agent-second after free trial).

## Teardown when finished

```bash
unset AWS_PROFILE AWS_REGION

# 1. Recover any outstanding faults
demo-cases/faults/recover-all.sh

# 2. Destroy webhook-bridge workspaces
cd demo-cases/infra/webhook-bridge/terraform
terraform workspace select bjs1
terraform destroy -input=false -auto-approve -var-file=/tmp/wb-bjs1.tfvars
terraform workspace select china
terraform destroy -input=false -auto-approve -var-file=/tmp/wb-china.tfvars

# 3. Destroy the stacks
cd ../../bjs1-stack && terraform destroy -input=false -auto-approve
cd ../china-stack && terraform destroy -input=false -auto-approve

# 4. Manually delete (per SETUP-AGENT-SPACE.md § 8)
#    - Webhook in DevOps Agent console
#    - SSM parameters /devops-agent/webhook-url and /webhook-secret in both accounts
#    - GitHub + Slack integrations in Agent Space
#    - Skill uploads (optional)
```
