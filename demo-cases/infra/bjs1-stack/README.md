# bjs1-stack — Beijing (cn-north-1) demo infrastructure

Terraform for the **EKS web app stack** that drives Cases C1, C2, C4, C5, C6, C7, C9 of the
China-region 10-WOW-cases demo.

- **Account**: `107422471498`
- **Region**: `cn-north-1` (Beijing)
- **Partition**: `aws-cn`
- **AWS profile**: `ychchen-bjs1`
- **Reuses**: default VPC `vpc-0bf919360d6e5b484` (172.31.0.0/16) and its existing public subnets

## Quick start

> **CRITICAL environment quirk**: the harness sets `AWS_PROFILE=claude-code-DO-NOT-DELETE`
> and `AWS_REGION` as environment variables. Those override Terraform's `provider` block,
> so you **MUST** unset them before running `terraform`.

```bash
cd demo-cases/infra/bjs1-stack
unset AWS_PROFILE AWS_REGION

terraform init
terraform plan
terraform apply
```

After apply, set up `kubectl`:

```bash
$(terraform output -raw kubectl_config_command)
kubectl --context bjs1 get nodes
```

## What gets created

| Resource | Spec | Notes |
|---|---|---|
| EKS cluster `bjs-web` | v1.31, control plane | API public+private endpoint |
| Managed nodegroup | 1 × t3.medium, AmazonLinux2 | desired=1, max=2, gp3 disk 20GB |
| RDS `bjs-todo-db` | Postgres 16.4, db.t3.micro, **single-AZ (L1 fault)** | Performance Insights on, password in Secrets Manager |
| ECR `bjs-todo-api` | Scan on push | Lifecycle: keep last 10 images |
| S3 `bjs-todo-uploads-<rand>` | KMS-CMK encrypted, BlockPublicAccess on, TLS-only | versioning enabled |
| IAM `bjs-web-alb-controller` | IRSA role for AWS Load Balancer Controller | Used by Phase-2 Helm install |
| IAM `bjs-cross-partition-test-role` | **Deliberately broken (L7 fault)** | See section below |
| SNS topic `bjs-web-alarms` | Single fan-out topic | Phase-2 webhook bridge subscribes here |
| CloudWatch alarms | `bjs-web-pod-not-ready`, `bjs-web-p99-latency-high`, `bjs-web-alb-5xx-rate-high` | Drive C1, C2/C9, C4 |
| CloudWatch log group | `/aws/eks/bjs-web/application` | 30-day retention |
| OIDC provider | Cluster issuer registered with IAM | Required for any IRSA |

## Phase-2 follow-ups (NOT in this Terraform)

The deploy script will:

1. `helm install aws-load-balancer-controller` using `outputs.alb_controller_role_arn`.
2. `helm install` the `bjs-todo-api` chart (creates the internal ALB via Ingress).
3. Update the two ALB-dimensioned alarms to point at the real LoadBalancer ARN suffix
   (Terraform leaves them with `app/bjs-web/placeholder` because the ALB doesn't exist yet).
4. Subscribe the webhook-bridge Lambda to the `bjs-web-alarms` SNS topic.

## Deliberate fault: L7 — cross-partition IAM trust ARN

`iam.tf` creates `bjs-cross-partition-test-role` with this trust policy:

```json
{
  "Effect": "Allow",
  "Principal": { "AWS": "arn:aws:iam::*:user/lambda-test" },
  "Action": "sts:AssumeRole"
}
```

This is **wrong on purpose**. The role lives in cn-north-1 (`aws-cn` partition),
so the principal ARN should be `arn:aws-cn:iam::*:user/lambda-test`. The native
DevOps Agent typically misdiagnoses this as "missing permission"; our custom skill
`cn-partition-arn-routing` corrects it. Case **C5** demonstrates the diff.

**Do not fix this.** It is the demo.

## Cost (14-day target ≤ ¥230)

| Component | 14-day cost |
|---|---|
| EKS control plane (¥260/mo) | ~¥120 |
| 1 × t3.medium node (¥75/mo) | ~¥35 |
| RDS db.t3.micro single-AZ + 20GB gp3 (~¥60/mo) | ~¥30 |
| ALB (Phase-2 only, ~¥60/mo while up) | ~¥30 (≈ 7 days up) |
| S3 + KMS + ECR + SNS + CloudWatch | ~¥10 |
| **Total** | **~¥225** |

ALB is provisioned by the Helm chart in Phase 2 and torn down in cleanup.

## Teardown

```bash
unset AWS_PROFILE AWS_REGION

# Tear down Phase-2 first (Helm releases create ALBs / SGs Terraform doesn't track).
helm uninstall bjs-todo-api -n bjs-web || true
helm uninstall aws-load-balancer-controller -n kube-system || true

terraform destroy
```

If `terraform destroy` complains about ENIs from Helm-created ALBs, delete the
ALB and target groups in the EC2 console, wait 60s, then retry destroy.
