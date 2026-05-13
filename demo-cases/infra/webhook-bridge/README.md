# webhook-bridge

Lambda function that bridges CloudWatch alarms (in AWS China regions) to the
AWS DevOps Agent webhook (only available in non-China commercial regions).

## Why this exists

AWS DevOps Agent has no presence in the `aws-cn` partition. CloudWatch alarms
in `cn-north-1` / `cn-northwest-1` therefore can't directly invoke the
DevOps Agent webhook through native EventBridge / API Gateway integrations.

The flow we want:

```
CloudWatch Alarm (cn-northwest-1)
       v
SNS Topic       (cn-northwest-1)        <-- alarm action target
       v
THIS LAMBDA     (cn-northwest-1)
       v
HTTPS POST + HMAC-SHA256 signature
       v
DevOps Agent webhook (us-east-1, public internet)
```

The Lambda:
1. Subscribes to one or more SNS topics (one per "case category").
2. Pulls the webhook URL + secret from SSM Parameter Store at cold start.
3. Reformats the CloudWatch alarm SNS payload into the
   [DevOps Agent webhook schema](../../../aws-docs/03-building-end-to-end-agentic-sre.md).
4. Signs with HMAC-SHA256, posts.

On a webhook 4xx/5xx the Lambda LOGS the failure but does not raise -- SNS is
fire-and-forget for incident notifications, and we'd rather drop one alert
than have SNS retry-storm a flaky DevOps Agent.

## Repo layout

```
webhook-bridge/
  src/
    handler.py            # Lambda entrypoint + helpers
    requirements.txt      # empty (stdlib + bundled boto3 only)
  tests/
    test_handler.py       # unittest-based unit tests
    sample_event.json     # Real-shape SNS-from-CloudWatch event
  terraform/
    main.tf               # IAM, Lambda, SNS subscriptions
    variables.tf
    outputs.tf
    README.md             # deploy instructions
```

## Local testing

No external deps needed:

```bash
cd demo-cases/infra/webhook-bridge
python -m py_compile src/handler.py
python -m unittest tests.test_handler -v
```

To exercise the handler against the sample event with mocked SSM/HTTP, see
`tests/test_handler.py::HandlerTestCase::test_lambda_handler_signs_and_posts_to_webhook`.

## Deployment

See `terraform/README.md`. Short version:

```bash
# 1. In the DevOps Agent console (non-China account), create a webhook.
# 2. In the China account, write the URL and secret into SSM:
aws ssm put-parameter --region cn-north-1 \
  --name /devops-agent/webhook-url --type String --value "https://..."
aws ssm put-parameter --region cn-north-1 \
  --name /devops-agent/webhook-secret --type SecureString --value "..."

# 3. Apply Terraform (do NOT keep AWS_PROFILE/AWS_REGION env vars set):
unset AWS_PROFILE AWS_REGION
cd terraform
terraform init
terraform apply -var 'aws_region=cn-north-1' \
                -var 'name_prefix=devops-agent-bridge-bjs1' \
                -var 'sns_topic_arns=["arn:aws-cn:sns:cn-north-1:...:demo-alarms"]'
```

Both bjs1 and china stacks share the same Terraform module - the only differences
between them are `aws_region`, `name_prefix`, and the list of SNS topic ARNs.

## Payload schema (output of this Lambda)

```json
{
  "eventType": "incident",
  "incidentId": "<alarm-name>-<state-change-time>",
  "action": "created | updated | resolved",
  "priority": "CRITICAL | HIGH | MEDIUM | LOW | MINIMAL",
  "title": "<alarm name>",
  "description": "<alarm description, falls back to NewStateReason>",
  "timestamp": "<ISO8601 UTC, generated at send time>",
  "service": "ALB | RDS | Lambda | CloudWatchLogs | ...",
  "data": {
    "alarmName": "...",
    "alarmDescription": "...",
    "newStateValue": "ALARM | OK | INSUFFICIENT_DATA",
    "newStateReason": "...",
    "stateChangeTime": "...",
    "region": "...",
    "accountId": "...",
    "resources": [...],
    "trigger": {"metricName": "...", "namespace": "AWS/...", "statistic": "..."}
  }
}
```

### State -> action mapping

| CloudWatch state | DevOps Agent action |
|---|---|
| `ALARM` | `created` |
| `OK` | `resolved` |
| `INSUFFICIENT_DATA` | `updated` |

### Priority resolution

1. CloudWatch alarm tag `Priority` (case-insensitive) if it's one of
   `CRITICAL/HIGH/MEDIUM/LOW/MINIMAL`. Requires `cloudwatch:ListTagsForResource`.
2. Namespace heuristic (`AWS/Logs` -> `LOW`, `AWS/ApplicationELB` -> `HIGH`, ...).
3. Default `HIGH`.

## Operational notes

- **Cold start cost**: SSM `GetParameters` (1 round trip, both params batched).
  Cached for the life of the execution environment.
- **Retries**: urllib3 retries are disabled on purpose. SNS will not retry
  Lambda invocations because we always return cleanly. End result: one webhook
  POST per alarm transition. Acceptable for incident signals.
- **Secret rotation**: rotate the webhook in the DevOps Agent console, then
  overwrite the SSM SecureString. The next cold start picks it up. Force a
  cold start by editing the function's environment variables (a no-op tweak).
