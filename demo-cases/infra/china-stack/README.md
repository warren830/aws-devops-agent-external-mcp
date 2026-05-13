# china-stack — ECS Fargate data service (Ningxia / cn-northwest-1)

Terraform for the **`ychchen-china`** account half of the AWS DevOps Agent
10-case demo (see `docs/superpowers/specs/2026-05-13-china-region-10-wow-cases-design.md`,
section 1.2).

## What it builds

| Resource | Purpose |
|---|---|
| ECS cluster `china-data` (Fargate, Container Insights ON) | Runtime |
| ECS service `etl-worker` | SQS → DynamoDB worker. Task is **0.25 vCPU / 512 MB**, container memory **256 MB** (deliberately too small — drives C3 / fault L5) |
| ECS service `report-generator` | 0.5 vCPU / 1 GB, cron-style (desired=0) |
| EventBridge Scheduler `etl-trigger-daily` | Daily 00:00 UTC (08:00 Beijing) |
| Lambda `etl-trigger` (Python 3.12) | Pushes 100 stub items into SQS |
| SQS queue `etl-jobs` (+ DLQ) | ETL job feed |
| DynamoDB `etl-state` | On-demand. C3 / L5 inject script flips to provisioned 5 WCU |
| RDS MySQL `china-data-db` (db.t3.micro, **multi-AZ ✅**) | Cross-account compare with bjs1 single-AZ in C4 / C8 |
| S3 `china-data-output-<rand>` | **Private base**. C10 / L2 inject toggles public |
| S3 `china-data-input-<rand>` | Private + KMS, always |
| ECR `etl-worker` | Image repo for both ECS tasks (until split) |
| SNS `china-data-alarms` + 3 CloudWatch alarms | C3 + C10 drivers |
| IAM roles | task exec, task, lambda, scheduler |

All resources reuse the **existing default VPC** `vpc-046d31d4731d50516`
(172.31.0.0/16). The non-default VPC `vpc-012c798aaaa59d2df` is intentionally
ignored — old experiment.

## Account / partition

- **Profile**: `ychchen-china`
- **Account**: `284567523170`
- **Region**: `cn-northwest-1`
- **Partition**: `aws-cn` (resolved via `data.aws_partition.current.partition`,
  used for managed-policy ARNs)

## Environment quirk — `AWS_PROFILE` override

This shell environment has `AWS_PROFILE=claude-code-DO-NOT-DELETE` set
globally. It overrides the profile baked into `providers.tf`. **Always**
clear it before running terraform:

```bash
unset AWS_PROFILE AWS_REGION
```

(The same applies to any `aws ...` CLI calls used by inject scripts.)

## Usage

```bash
unset AWS_PROFILE AWS_REGION

terraform init
terraform plan
terraform apply
```

For validation only (no backend, no AWS calls):

```bash
unset AWS_PROFILE AWS_REGION
terraform init -backend=false
terraform validate
```

## Cost target

≤ ¥120 over 14 days (per design doc § 1.2 cost table).

Biggest line items:
- RDS multi-AZ db.t3.micro ≈ ¥120/mo prorated → ¥56/14d
- Fargate etl-worker continuous (0.25 vCPU) ≈ ¥30/mo
- Everything else < ¥10/mo

The output bucket starts **private**. Container Insights is on (small surcharge,
necessary for C3). KMS key has 7-day deletion window so destroy returns a usable
key allowance.

## Image bootstrap

The two ECS task definitions reference `${ecr_repo_url}:latest` by default
(see `var.etl_image` / `var.report_image`). On first apply the ECR repo
exists but has no `:latest` tag — the services will sit in pending image
pull until you push something. A trivial bootstrap:

```bash
unset AWS_PROFILE AWS_REGION

REGION=cn-northwest-1
ACCOUNT=284567523170
REPO=$(terraform output -raw ecr_repo_url)

aws ecr get-login-password --profile ychchen-china --region "$REGION" \
  | docker login --username AWS --password-stdin "$REPO"

# Smallest possible amd64 image — works for the placeholder until real ETL code lands
docker pull --platform=linux/amd64 public.ecr.aws/docker/library/python:3.12-slim
docker tag public.ecr.aws/docker/library/python:3.12-slim "$REPO:latest"
docker push "$REPO:latest"
```

## Faults driven by this stack

| Fault | What | Inject script (C-prefix) |
|---|---|---|
| L2 | `china-data-output` toggle public + add public-read policy | C10 |
| L5 | `etl-state` flip to provisioned 5 WCU + scale `etl-worker` desired=5 | C3 |

Lifecycle `ignore_changes` is set on:
- `aws_dynamodb_table.etl_state.billing_mode` / capacity
- `aws_s3_bucket_public_access_block.output.*`
- `aws_ecs_service.etl_worker.desired_count`
- `aws_ecs_service.report_generator.desired_count`

…so that injection scripts don't fight terraform on subsequent plans.

## Files

| File | Contents |
|---|---|
| `versions.tf` | TF + provider version pins |
| `providers.tf` | aws provider w/ default tags |
| `variables.tf` | inputs |
| `data.tf` | partition / region / VPC / subnets |
| `locals.tf` | derived locals (partition, image refs, tags) |
| `random.tf` | random_id suffix for bucket names |
| `ecr.tf` | repo + lifecycle |
| `ecs.tf` | cluster + 2 task defs + 2 services + SG |
| `rds.tf` | MySQL multi-AZ + subnet group + SG |
| `dynamodb.tf` | etl-state table |
| `sqs.tf` | etl-jobs queue + DLQ |
| `lambda.tf` | etl-trigger function |
| `lambda/handler.py` | placeholder Python that batches 100 SQS messages |
| `eventbridge.tf` | daily 00:00 UTC scheduler |
| `s3.tf` | output (private base) + input (private + KMS) buckets |
| `iam.tf` | task-exec / task / lambda / scheduler roles + policies |
| `cloudwatch.tf` | SNS topic + 3 alarms |
| `outputs.tf` | exported values for inject scripts and case docs |
