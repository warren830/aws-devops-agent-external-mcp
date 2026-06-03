---
name: deploy-mcp-bridge
description: >
  End-to-end deployment knowledge for wiring AWS DevOps Agent to a self-hosted
  MCP Server bridge into AWS China region accounts. Use this skill whenever the
  user wants to "部署", "deploy", "配置", "set up", "接入", "onboard", "加账号",
  "add account", "rotate cert", "轮换证书", or troubleshoot the MCP bridge
  (ECS Fargate + internal ALB + VPC Lattice Private Connection + IAM Roles
  Anywhere). It covers the full lifecycle: network, certificates, Hub/Spoke
  Roles Anywhere, ECS deploy, Agent Space registration, and day-2 ops. The
  skill encodes the exact commands, decision points, and known pitfalls
  (RequestExpired credential refresh, Private-Connection-blocks-SG-delete,
  ECR token expiry, DNS resolution = Public). It does NOT itself run commands —
  it is the knowledge the deploy agent follows.
---

# Deploy MCP Bridge to AWS China Region

This skill is the **knowledge layer** for deploying the AWS DevOps Agent →
self-hosted MCP Server bridge. The `mcp-deployer` subagent follows this skill
to interactively guide and execute a deployment.

## Safety contract (MANDATORY)

This deployment touches real AWS resources across multiple accounts and
partitions. Apply these rules at every step:

1. **Read freely**: `describe` / `list` / `get` / `terraform plan` / `cfn
   describe-stacks` need no confirmation.
2. **Confirm before write**: `terraform apply`, `cloudformation deploy`,
   `aws ... create/update`, `docker push`, `ecs update-service` — show what
   will change and get explicit user confirmation first.
3. **Double-confirm destroy**: `terraform destroy`, `delete-secret`,
   `delete-security-group`, deleting CFN stacks or Private Connections —
   STOP, explain the blast radius (what breaks, is it reversible), and require
   a second explicit confirmation. Never destroy production without it.
4. **Assume production when uncertain**: if you cannot tell whether an account
   is prod, treat it as prod.
5. **Prefer least privilege**: use ReadOnly credentials/roles for inspection.

## Architecture in one breath

```
AWS DevOps Agent (Agent Space)
  → VPC Lattice Private Connection (Resource Gateway)
  → Internal ALB (HTTPS:443, host-based routing, ACM public cert)
  → ECS Fargate task per account (MCP Server, official awslabs package)
  → AWS China APIs, authenticated via IAM Roles Anywhere (cert → Hub → Spoke)
```

Two auth modes coexist via `auth_mode` in `terraform-ecs/terraform.tfvars`:
`ak_sk` (long-lived keys) and `roles_anywhere` (X.509 → 1h temp creds, Hub-Spoke
fan-out). Aliyun/other clouds stay `ak_sk` (Roles Anywhere is AWS-only).

## Pre-flight: gather these before touching anything

Ask the user (or detect) and record:

| Item | How to get | Example |
|------|-----------|---------|
| Global account (ECS host) | `aws sts get-caller-identity` | `<GLOBAL_ACCOUNT_ID>` |
| China Hub account + region | China profile | `<CN_NW_ACCOUNT_ID>` / cn-northwest-1 |
| China Spoke account(s) | per target | `<CN_N_ACCOUNT_ID>` / cn-north-1 |
| AWS profiles per account | `~/.aws/config` | `cn-nw-profile`, `cn-n-profile` |
| ACM public cert ARN | must exist in us-east-1 | wildcard `*.example.cloud` |
| VPC + 2 public + 2 private subnets | existing or auto-create | — |
| Auth mode | user choice | `roles_anywhere` (recommended) |

**Hard rules learned the hard way**:
- `sts:AssumeRole` cannot cross partition → Hub MUST be in `aws-cn`, same
  partition as Spokes.
- ACM cert for the ALB must be a **public** cert in `us-east-1` (Lattice TLS
  trusts public CA chains; self-signed needs manual PEM upload).
- Hub and Spoke MAY be the same account (Hub Role assumes a Spoke Role in its
  own account) — valid and the simplest starting topology.

## Deployment phases

Follow `DEPLOY-RA-RECORD.md` and `DEPLOY-ROLES-ANYWHERE.md` for exact commands.
This skill is the decision spine; those docs are the command reference.

### Phase 0 — Decide auth mode & topology
- Recommend `roles_anywhere` for prod (no long-lived keys, CRL revocable,
  Hub-Spoke O(1) account add). `ak_sk` only for quick dev validation or
  non-AWS clouds.
- Pick which China account is Hub. Single-account Hub+Spoke is the lowest-risk
  way to validate the whole chain first.

### Phase 1 — Clean slate (only if rebuilding)
- `terraform destroy` in `terraform-ecs/` (DOUBLE-CONFIRM — destroys ALB, NAT,
  ECS, ~32 resources).
- **PITFALL**: the ALB Security Group won't delete while a VPC Lattice Resource
  Gateway ENI references it. You MUST delete the Private Connection in Agent
  Space Console FIRST (outside-in: MCP Servers → uncheck, MCP Server registry →
  delete, Private connections → delete), wait for ENI release, then
  `aws ec2 delete-security-group` + `terraform state rm aws_security_group.alb`.
- Delete stale AK/SK secrets if migrating to Roles Anywhere.

### Phase 2 — Certificates + Roles Anywhere
1. `cfn/generate-certs.sh ~/mcp-certs` → CA (10y, keep `ca.key` OFFLINE) +
   client cert (1y → Secrets Manager).
2. Deploy Hub CFN (`cfn/roles-anywhere-hub.yaml`) in the China Hub account.
   `SpokeRoleArns` is a comma-separated list — adding an account later = append
   one ARN + re-deploy (idempotent). Record TrustAnchorArn / ProfileArn /
   HubRoleArn outputs.
3. Deploy Spoke CFN (`cfn/roles-anywhere-spoke.yaml`) in EACH target account
   (including the Hub account if it's also a Spoke). Trust policy pins
   `sts:ExternalId = mcp-bridge` (confused-deputy guard).
4. Store client cert + key as PLAIN PEM in Secrets Manager (`/mcp/ra-cert`,
   `/mcp/ra-key`) in us-east-1. Record the full ARNs (random suffix).

### Phase 3 — ECS deploy
- **No Terraform code changes needed** — only edit `terraform.tfvars`: add the
  `roles_anywhere {}` block + set each account's `auth_mode = "roles_anywhere"`
  + `spoke_role_arn`. Remove `access_key`/`secret_key`. (`ecs.tf`/`secrets.tf`/
  `iam.tf` already branch on `auth_mode`.)
- `terraform apply` (CONFIRM — ~34 resources).
- Build the RA image with `deploy/Dockerfile.ra` (NOT `Dockerfile` — the RA
  image adds `aws_signing_helper` + `jq` + `awscli` + credential scripts).
  **PITFALL**: ECR login token expires in 1h — re-run `aws ecr get-login-password
  | docker login` right before `docker push` if the build was slow.
- `aws ecs update-service --force-new-deployment` for each service.

### Phase 4 — Agent Space registration (Console, manual)
- **Private Connection**: VPC + 2 private subnets + ALB Security Group ID;
  **Host address = the ALB AWS DNS name** (`internal-*.elb.amazonaws.com`), NOT
  the `*.example.cloud` domain; **DNS resolution = Public** (the elb domain is
  publicly resolvable; "In VPC" fails); **Certificate public key = leave EMPTY**
  (ACM public cert is trusted by default — pasting placeholder text breaks TLS).
  Wait ~10 min for `Completed`.
- **Register MCP Server** per host: Endpoint = `https://<host>.example.cloud/mcp`
  (the domain, not ALB DNS — ALB does host-based routing on it); check "Connect
  using a private connection" → select the connection (MUST check, else it goes
  over public internet and the private ALB IP is unreachable). Reuse ONE Private
  Connection for all hosts.
- **Agent Space → MCP Servers → Add** each registered server → Allow tools.

### Phase 5 — Verify
- `aws ecs describe-services` → running == desired.
- Target group health → `healthy`.
- Container logs show `[entrypoint-ra] credential_process configured` +
  `Initial credential fetch OK` + `Starting MCP server`.
- In Agent: "查一下 aws-cn 的 VPC 列表" returns China-account resources via an
  MCP-prefixed tool.

## Known pitfalls (the expensive lessons)

| Symptom | Root cause | Fix |
|---------|-----------|-----|
| `RequestExpired` after ~1h | Old entrypoint injected creds as env vars + a background refresh loop, but a running process's env can't be mutated → server pinned to the first 1h token. | Use SDK-native `credential_process`: `entrypoint-ra.sh` writes `AWS_CONFIG_FILE` with `credential_process = credential-helper.sh`; botocore lazily refreshes by `Expiration`. `credential-helper.sh` must `unset AWS_PROFILE AWS_CONFIG_FILE` before its inner `aws sts assume-role` (recursion guard). |
| SG won't delete on destroy | VPC Lattice Resource Gateway ENI still references it | Delete Private Connection in Agent Space Console first; wait for ENI release |
| `docker push` 403 | ECR login token expired (1h) | re-login before push |
| Private Connection `ValidationException` | Host address set to `*.example.cloud` instead of ALB DNS name | Host address = ALB AWS DNS name |
| CNAME not resolving publicly | Confusion: ALB DNS is public; `*.example.cloud` is private-zone only | Expected — that's why Host address uses ALB DNS |
| `connect to endpoint failed` | ECS task can't reach China endpoint | check NAT Gateway + SG egress 443 |

## Day-2 operations

- **Add a Spoke account**: deploy spoke CFN in new account → append its Role ARN
  to Hub `SpokeRoleArns` + re-deploy Hub → add account entry in tfvars →
  `terraform apply` → Agent Space register (reuse Private Connection). No new
  long-lived keys are ever created.
- **Rotate client cert (yearly)**: re-sign with existing CA, update the two
  Secrets Manager secrets, `ecs update-service --force-new-deployment`. Trust
  Anchor trusts the CA, not a specific cert — no Roles Anywhere config change.
- **Emergency revoke**: disable Trust Anchor (seconds, all connections) or
  upload a CRL (seconds, single cert) or delete a Spoke's CFN stack (minutes,
  single account).

## Reference files in this repo

- `DEPLOY-RA-RECORD.md` — full real deployment log with exact commands
- `DEPLOY-ROLES-ANYWHERE.md` — Roles Anywhere deployment guide + troubleshooting
- `REBUILD.md` — teardown + rebuild runbook
- `cfn/` — `generate-certs.sh`, `roles-anywhere-hub.yaml`, `roles-anywhere-spoke.yaml`
- `terraform-ecs/` — ECS Fargate IaC (auth_mode-driven)
- `deploy/Dockerfile.ra`, `entrypoint-ra.sh`, `credential-helper.sh`
