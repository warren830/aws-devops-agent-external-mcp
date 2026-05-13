# webhook-bridge Terraform stack

Deploys the SNS -> Lambda -> DevOps Agent webhook bridge in a China-region AWS
account (bjs1 = `cn-north-1`, china = `cn-northwest-1`).

## Prerequisites (one-time, manual)

1. **Create the DevOps Agent webhook in your global / non-China account** via
   the AWS DevOps Agent console. Pick "Generate webhook" and copy:
   - the unique webhook URL
   - the unique secret (shown ONCE - if you miss it, regenerate)

2. **Write those values into SSM Parameter Store in the China account where
   you'll deploy this stack.** Two parameters under `/devops-agent/`:

   ```bash
   # cn-north-1 example (bjs1 stack)
   aws ssm put-parameter \
     --region cn-north-1 \
     --name /devops-agent/webhook-url \
     --type String \
     --value "https://<unique>.execute-api.us-east-1.amazonaws.com/incidents/v1/webhook"

   aws ssm put-parameter \
     --region cn-north-1 \
     --name /devops-agent/webhook-secret \
     --type SecureString \
     --value "<paste-the-secret>"
   ```

   Use a different SSM prefix per environment if you want to share an account
   between bjs1 and china (set `var.ssm_parameter_prefix`).

3. **Have an existing SNS topic (or topics)** that your CloudWatch alarms
   already publish to. The CloudWatch alarms must live in the SAME region as
   this stack.

## Environment quirk

Operators have hit shell-state interference between AWS partitions. **Before
running terraform, unset profile/region overrides** so your `default` profile
+ provider `region` are authoritative:

```bash
unset AWS_PROFILE AWS_REGION
aws sts get-caller-identity --region cn-north-1     # sanity check
```

If you keep China credentials in a named profile, set just `AWS_PROFILE` and
leave `AWS_REGION` unset (the provider's `region` argument wins).

## Deploy

```bash
cd terraform

# bjs1 example
terraform init
terraform apply \
  -var 'aws_region=cn-north-1' \
  -var 'name_prefix=devops-agent-bridge-bjs1' \
  -var 'sns_topic_arns=["arn:aws-cn:sns:cn-north-1:111122223333:demo-alarms-alb","arn:aws-cn:sns:cn-north-1:111122223333:demo-alarms-rds"]'
```

For the `china` (Ningxia) account, swap region to `cn-northwest-1` and adjust
the SNS topic ARNs accordingly.

## Variables

| Variable | Required | Notes |
|---|---|---|
| `aws_region` | yes | `cn-north-1` or `cn-northwest-1` (or any commercial region for testing). |
| `sns_topic_arns` | yes | List of SNS topic ARNs to subscribe. One per case category. |
| `name_prefix` | no | Default `devops-agent-bridge`. Set per-stack to avoid collisions. |
| `ssm_parameter_prefix` | no | Default `/devops-agent`. Override per environment. |
| `ssm_secret_kms_key_arn` | no | If null, the policy allows `kms:Decrypt` only via the AWS-managed `alias/aws/ssm` key. Pass a CMK ARN to scope tighter. |
| `lambda_memory_mb` | no | Default 256. |
| `lambda_timeout_seconds` | no | Default 30. |
| `lambda_log_retention_days` | no | Default 14. |

## What gets created

- `aws_lambda_function.bridge` (Python 3.12)
- `aws_iam_role.lambda` plus four inline policies (logs, ssm, kms, cloudwatch tags)
- `aws_cloudwatch_log_group.lambda` (`/aws/lambda/<name_prefix>`)
- `aws_lambda_permission.sns[*]` (one per topic)
- `aws_sns_topic_subscription.bridge[*]` (one per topic)

The Lambda code is built from `../src` automatically by the `archive_file` data
source.

## Verifying the deploy

1. Find the function in the AWS console (Lambda -> Functions -> your name_prefix).
2. Trigger a CloudWatch alarm into ALARM state (the easiest way: `aws cloudwatch
   set-alarm-state --alarm-name <name> --state-value ALARM --state-reason 'manual test'`).
3. Tail the Lambda logs:
   ```bash
   aws logs tail /aws/lambda/devops-agent-bridge-bjs1 --follow --region cn-north-1
   ```
   You should see `webhook_post_result` entries with `status:202` (or whatever the
   DevOps Agent webhook returns on success).

## Tearing down

```bash
terraform destroy -var ...
```

The SSM parameters are NOT managed by this stack and will not be deleted - if
you want to rotate the webhook, regenerate it in the DevOps Agent console and
overwrite the SSM values.
