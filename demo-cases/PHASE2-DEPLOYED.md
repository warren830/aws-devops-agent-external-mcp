# Phase 2 — Deployed Infrastructure (Snapshot)

Generated 2026-05-14. All resources in two China region accounts.

## ychchen-bjs1 (107422471498) — cn-north-1 / Beijing — Web App Stack

| Resource | Identifier | State |
|---|---|---|
| EKS cluster | `bjs-web` v1.31 | Active |
| Node group | 1 × t3.medium AL2 | Ready |
| RDS PostgreSQL | `bjs-todo-db` 16.13 (single-AZ ⚠ L1) | Available |
| Internal ALB | `internal-k8s-bjsweb-todoapi-c36eae0a01-108833280.cn-north-1.elb.amazonaws.com.cn` | active |
| Ingress host header | `bjs-web.yingchu.cloud` | listener :80 only (HTTP, no ACM cert in cn) |
| ECR repo | `bjs-todo-api` | image `v1.2.3` + `latest` pushed |
| EKS app | `bjs-web/todo-api` | 3/3 Running |
| S3 uploads bucket | `bjs-todo-uploads-7fa29e` | Private + KMS |
| Webhook bridge Lambda | `devops-agent-bridge-bjs1` | Active, subscribed to `bjs-web-alarms` SNS |
| Cross-partition test role | `bjs-cross-partition-test-role` | Created with VALID baseline trust (L7 inject script mutates) |
| SSM | `/devops-agent/webhook-url`, `/devops-agent/webhook-secret` | placeholder values (replace per SETUP-AGENT-SPACE.md) |

**CloudWatch alarms** (publish to `bjs-web-alarms` SNS → bridge Lambda → DevOps Agent webhook):
- `bjs-web-pod-not-ready`
- `bjs-web-p99-latency-high`
- `bjs-web-alb-5xx-rate-high`

## ychchen-china (284567523170) — cn-northwest-1 / Ningxia — Data Service Stack

| Resource | Identifier | State |
|---|---|---|
| ECS cluster | `china-data` (Fargate) | Active, Container Insights enabled |
| ECS service | `etl-worker` | 1/1 Running |
| ECS service | `report-generator` | 0/0 (cron-style, scaled to 0) |
| RDS MySQL | `china-data-db` 8 (multi-AZ ✅) | Available |
| DynamoDB | `etl-state` PAY_PER_REQUEST | Active |
| SQS | `etl-jobs` | Created |
| Lambda | `etl-trigger` (daily 00:00 UTC schedule) | Active |
| ECR repo | `etl-worker` | image `latest` pushed |
| S3 output bucket | `china-data-output-4fca6718` | Private + KMS (C10 inject toggles public) |
| S3 input bucket | `china-data-input-4fca6718` | Private + KMS |
| Webhook bridge Lambda | `devops-agent-bridge-china` | Active, subscribed to `china-data-alarms` SNS |
| SSM | `/devops-agent/webhook-url`, `/devops-agent/webhook-secret` | placeholder values |

**CloudWatch alarms** (publish to `china-data-alarms` SNS → bridge Lambda → DevOps Agent webhook):
- `ecs-etl-task-failures`
- `dynamodb-etl-state-throttle`
- `china-cost-anomaly` (placeholder; cost driver is Cost Explorer + skill, see C10)

## What's NOT yet done — manual steps before Phase 4

1. **DevOps Agent Space console** (per `SETUP-AGENT-SPACE.md` § 2):
   - Generate the real webhook URL + secret
   - Replace SSM placeholder values in **both** accounts
   - Connect GitHub for `bjs-todo-api` repo (drives C2 / C7)
   - Connect Slack for `#bjs-web-incidents` channel (drives C1 output)
   - Upload `cn-partition-arn-routing` skill (drives C5)
2. **GitHub repo creation**: push `demo-cases/app/bjs-todo-api/` to a real GitHub repo so the agent can read commits.
3. **Real ALB DNS to yingchu.cloud DNS**: Tencent DNSPod CNAME `bjs-web` → ALB DNS, so `bjs-web.yingchu.cloud` resolves.

## Quick commands

```bash
unset AWS_PROFILE AWS_REGION

# Get app pod
kubectl --context bjs1 -n bjs-web get pods

# Smoke test the app from inside the cluster
APP_POD=$(kubectl --context bjs1 -n bjs-web get pod -l app=todo-api -o jsonpath='{.items[0].metadata.name}')
ALB=internal-k8s-bjsweb-todoapi-c36eae0a01-108833280.cn-north-1.elb.amazonaws.com.cn
kubectl --context bjs1 -n bjs-web exec $APP_POD -- python3 -c "
import urllib.request
req = urllib.request.Request('http://$ALB/healthz', headers={'Host':'bjs-web.yingchu.cloud'})
print(urllib.request.urlopen(req, timeout=5).read().decode())
"

# Trigger a fault (e.g. C1 EKS ImagePullBackOff)
cd demo-cases/faults
./inject-L6-pod-imagepullbackoff.sh

# Recover
./recover-L6-pod-imagepullbackoff.sh
```
