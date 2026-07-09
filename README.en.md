# aws-devops-agent-external-mcp

[中文](./README.md) | **English**

Connect **AWS DevOps Agent** to self-hosted MCP Servers, with end-to-end calls staying on private networking via VPC Lattice Private Connection. Two deployment options are supported: **ECS Fargate** (recommended) and **EKS**.

**Zero business code** — every MCP Server is an official package (`awslabs.aws-api-mcp-server`, `alibaba-cloud-ops-mcp-server`, etc.). This project only does containerization, orchestration, and AWS network wiring.

> 🚀 **ECS Fargate (recommended)**: a single `terraform apply` does everything, no K8s required (see Quick Start below)
> 🔐 **IAM Roles Anywhere (enterprise-grade)**: eliminate AK/SK — certificate + temporary credentials + Hub-Spoke multi-account → [docs/deploy/DEPLOY-ROLES-ANYWHERE.md](./docs/deploy/DEPLOY-ROLES-ANYWHERE.md)
> 📖 **Full EKS deployment steps**: [docs/legacy-eks/SETUP.md](./docs/legacy-eks/SETUP.md)
> 🐛 **War-story blog of pitfalls (fault isolation across 7 layers)**: [docs/blog/BLOG.md](./docs/blog/BLOG.md)
> 🏗️ **Multi-account scaling & operations guide** (Helm chart + ESO): [docs/legacy-eks/MULTI-ACCOUNT.md](./docs/legacy-eks/MULTI-ACCOUNT.md)
> 🔥 **Rebuild-from-scratch runbook** (destroy everything + redeploy Mode B on latest code): [docs/deploy/REBUILD.md](./docs/deploy/REBUILD.md)
> 📚 **Full documentation index** → [docs/README.md](./docs/README.md)

---

## Architecture

```
┌──────────────────┐      ┌─────────────────┐      ┌───────────────┐       ┌─────────────────────────┐
│ AWS DevOps Agent │──────│ Private         │──────│ Internal ALB  │───┬──→│ aws-cn (Fargate/Pod)    │
│ (Agent Space)    │ VPC  │ Connection      │ priv │ (HTTPS:443)   │   │   └─────────────────────────┘
└──────────────────┘ Lat. │ (Resource GW)   │ net  │ host-based    │   │   ┌─────────────────────────┐
                          └─────────────────┘      │ routing       │   ├──→│ aws-cn-2 (Fargate/Pod)  │
                                                   └───────────────┘   │   └─────────────────────────┘
                                                          ↑            │   ┌─────────────────────────┐
                                            ACM *.example.cloud        └──→│ aliyun-prod (Fargate)   │
                                                                           └─────────────────────────┘
```

**Key design decisions**:

| Decision | Rationale |
|---|---|
| **One ALB + host-based routing** | Multiple MCP Servers share a single Private Connection, and one certificate covers them all |
| **Public ACM certificate (not self-signed)** | The Lattice TLS handshake only trusts public CA chains by default; self-signed certs require manually uploading a PEM — tedious and error-prone |
| **Native Streamable HTTP (no supergateway)** | Removes the protocol bridge — one less failure surface. supergateway's stateless mode also has a crash bug |
| **`AWS_API_MCP_STATELESS_HTTP=true` + 2 replicas** | MCP's default stateful sessions break across replicas ("Session not found"). Stateless mode lets any pod serve any request |
| **Private Connection Host address = the ALB's AWS DNS name** | This field must be **publicly resolvable** (Lattice uses it for the DNS lookup). A private-zone domain returns NXDOMAIN |
| **DNS split-horizon** | The public side of `example.cloud` lives in Tencent DNSPod, the private side in a Route53 private zone — each managed independently |

---

## Two deployment options × two auth modes

### Deployment options

| | **ECS Fargate (recommended)** | **EKS** |
|---|---|---|
| Deploy command | `terraform apply` (one step) | terraform + helm×3 + kubectl (five steps) |
| Fixed monthly cost | ~$57 (NAT $32 + ALB $16 + Fargate ~$9/service) | ~$130 (NAT + ALB + EKS control plane $72 + nodes) |
| Adding an account | edit tfvars + `terraform apply` | write a values.yaml + `helm install` |
| Credential management | Secrets Manager read directly (native) | ESO + IRSA + ClusterSecretStore |
| Best for | most scenarios, teams without K8s | teams already on EKS, or running a dozen microservices |
| Directory | `terraform-ecs/` | `terraform/` + `chart/` + `chart-aliyun/` |
| Blog | 04 - ECS Fargate lightweight | 01 single account / 02 multi-account / 03 Skills in practice |

### Auth modes

| | **AK/SK (default)** | **IAM Roles Anywhere (recommended for enterprises)** |
|---|---|---|
| Credential type | long-lived Access Key / Secret Key | X.509 certificate → 1h temporary credentials |
| Blast radius on leak | valid forever until manually rotated | at most 1h; revocable within seconds via CRL |
| Credentials for N accounts | N AK/SK pairs | 1 certificate (Hub AssumeRole fan-out) |
| Adding an account | create an IAM User + store AK/SK | deploy the Spoke CFN (1 Role) |
| Best for | quick validation, dev environments | production, compliance-heavy enterprises |
| Setup guide | Quick Start below | [docs/deploy/DEPLOY-ROLES-ANYWHERE.md](./docs/deploy/DEPLOY-ROLES-ANYWHERE.md) |

The two auth modes can be **mixed within the same `accounts` map** (switched per entry via the `auth_mode` field).

---

## Repository layout

```
.
├── README.md                    ← Chinese README (README.en.md = this file)
├── docs/                        ← 📚 documentation (see docs/README.md for the index)
│   ├── README.md                ← documentation index
│   ├── deploy/                  ← 🔐 current recommended deployment docs
│   │   ├── DEPLOY-ROLES-ANYWHERE.md  ← IAM Roles Anywhere deployment guide
│   │   ├── DEPLOY-RA-RECORD.md       ← real deployment log (exact commands)
│   │   └── REBUILD.md                ← rebuild-from-scratch runbook
│   ├── legacy-eks/              ← ⚠️ legacy EKS path (prefer ECS instead)
│   │   ├── SETUP.md                  ← full EKS setup guide
│   │   └── MULTI-ACCOUNT.md          ← EKS multi-account operations (Helm + ESO)
│   └── blog/
│       └── BLOG.md                   ← war-story blog across 7 failure layers
├── docker-compose.yml           ← local smoke test
├── cfn/                         ← 🔐 IAM Roles Anywhere CloudFormation
│   ├── roles-anywhere-hub.yaml  ← Hub account (Trust Anchor + Profile + Hub Role)
│   ├── roles-anywhere-spoke.yaml← Spoke account (ReadOnly Role)
│   └── generate-certs.sh        ← one-shot CA + client certificate generation
├── deploy/
│   ├── Dockerfile               ← AWS MCP image (AK/SK mode)
│   ├── Dockerfile.ra            ← AWS MCP image (Roles Anywhere mode)
│   ├── Dockerfile.aliyun        ← Alibaba Cloud MCP image
│   ├── credential-helper.sh     ← cert → Hub credentials → AssumeRole → Spoke credentials
│   └── entrypoint-ra.sh         ← RA container launcher (writes certs + registers credential_process)
├── terraform-ecs/               ← ⭐ ECS Fargate path (recommended)
│   ├── main.tf                  ← provider
│   ├── variables.tf             ← accounts map (auth_mode: ak_sk | roles_anywhere)
│   ├── network.tf               ← IGW + NAT Gateway + route tables
│   ├── alb.tf                   ← internal ALB + HTTPS listener
│   ├── ecs.tf                   ← ECS Cluster + for_each Services
│   ├── iam.tf                   ← Execution Role + Task Role
│   ├── secrets.tf               ← secrets created conditionally per auth_mode
│   ├── outputs.tf               ← ALB DNS name + DNS follow-up hints
│   └── terraform.tfvars.example ← config template (examples for both auth modes)
├── terraform/                   ← EKS path infrastructure
│   └── main.tf                  ← VPC + EKS + IRSA
├── chart/                       ← EKS path Helm chart (AWS)
├── chart-aliyun/                ← EKS path Helm chart (Alibaba Cloud)
└── scripts/
    └── smoke.sh                 ← local docker-compose smoke test
```

---

## Quick Start

### 1️⃣ Local validation (no AWS resources needed)

```bash
cp .env.example .env
vim .env                        # fill in AWS / Alibaba Cloud credentials

docker compose up -d
bash scripts/smoke.sh           # sends an MCP initialize handshake to the local ports
```

### 2️⃣ Deploy to AWS — ECS Fargate (recommended)

Fill in a single config file; terraform creates everything (optionally auto-created VPC, ECR, Secrets Manager, ALB, ECS).

```bash
cd terraform-ecs
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` and provide 3 things:

```hcl
# 1. TLS certificate (public ACM certificate, request it beforehand)
certificate_arn = "arn:aws:acm:us-east-1:ACCOUNT:certificate/CERT_ID"

# 2. Target account credentials + hostname
accounts = {
  aws-cn = {
    host       = "aws-cn.example.com"     # your domain
    aws_region = "cn-northwest-1"
    access_key = "AKIA..."                # target account AK
    secret_key = "..."                    # target account SK
  }
}

# 3. VPC (optional — leave empty to auto-create, or fill in existing IDs)
# vpc_id             = "vpc-xxx"
# public_subnet_ids  = ["subnet-aaa", "subnet-bbb"]
# private_subnet_ids = ["subnet-ccc", "subnet-ddd"]
```

One-command deploy:

```bash
terraform init && terraform apply    # ~3 minutes, creates all infrastructure
```

After apply completes, push the image (first time only):

```bash
# terraform output prints the full commands; the following is an example
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin <ACCOUNT>.dkr.ecr.us-east-1.amazonaws.com
docker build --platform linux/amd64 -t <ECR_URL>:latest -f deploy/Dockerfile .
docker push <ECR_URL>:latest

# make ECS pull the image
aws ecs update-service --cluster mcp --service mcp-aws-cn --force-new-deployment
```

> Adding an account later = add one entry to `terraform.tfvars` + `terraform apply` — no new image push required.

See the Quick Start above and [docs/deploy/DEPLOY-ROLES-ANYWHERE.md](./docs/deploy/DEPLOY-ROLES-ANYWHERE.md) for details.

### 2️⃣-B Deploy to AWS — EKS

For teams that already run an EKS cluster. See [docs/legacy-eks/SETUP.md](./docs/legacy-eks/SETUP.md).

```bash
cd terraform && terraform apply
helm install aws-load-balancer-controller ...
helm install aws-cn ./chart -f values-aws-cn.yaml -n mcp
```

### 3️⃣ Configure AWS DevOps Agent (Agent Space console)

**Step A: Create a Private Connection**

Agent Space → Private Connections → Create

| Field | What to enter |
|------|--------|
| Name | anything (e.g. `ecs-mcp`) |
| VPC | the `vpc_id` from terraform output |
| Subnets | the private subnets |
| Security Groups | the `mcp-alb` SG |
| Host address | the value of `terraform output alb_dns_name` |
| Certificate | leave empty (public ACM certs need no extra PEM) |

Wait for the status to become Completed (up to 10 minutes).

**Step B: Register MCP Servers** (one per account)

Agent Space → Capabilities → MCP Servers → Add

| Field | What to enter |
|------|--------|
| Name | e.g. `aws-cn-mcp` |
| Endpoint URL | `https://<your-host>/mcp` (e.g. `https://aws-cn.example.com/mcp`) |
| Dynamic Client Registration | unchecked |
| Private Connection | the `ecs-mcp` connection created above |

**Step C: Verify**

In the Operator Web App, send: `List the VPCs in aws-cn`

Key principles:
- **Host address** takes the ALB DNS name — the Private Connection uses it to locate the ALB
- The domain inside the **Endpoint URL** — travels as the HTTP Host header; the ALB uses it to route to the matching ECS Service
- **One Private Connection is reused by all MCP Servers** — same ALB, differentiated by hostname

---

## What DevOps Agent requires of an MCP Server

| Requirement | How this project satisfies it |
|---|---|
| Streamable HTTP transport | `AWS_API_MCP_TRANSPORT=streamable-http` (natively supported by aws-api-mcp-server) |
| HTTPS endpoint | internal ALB + public ACM wildcard certificate `*.example.cloud` |
| Private reachability (no public exposure) | Private Connection (VPC Lattice Resource Gateway) |
| HA support (multiple replicas) | `AWS_API_MCP_STATELESS_HTTP=true` + replicas=2 |
| Health checks | Ingress `success-codes: "200,404,406"` to accommodate the MCP Server returning 406 to GET |

---

## Supplying credentials

### Mode A: AK/SK (default)

Injected as environment variables → read by boto3:

```yaml
env:
  - { name: AWS_DEFAULT_REGION,    value: "cn-north-1" }
  - { name: AWS_ACCESS_KEY_ID,     valueFrom: { secretKeyRef: { name: mcp-creds, key: AWS_CN_AK } } }
  - { name: AWS_SECRET_ACCESS_KEY, valueFrom: { secretKeyRef: { name: mcp-creds, key: AWS_CN_SK } } }
```

⚠️ **AWS China is a separate partition** — global-partition credentials fail with AuthFailure in China regions. You need a dedicated account from [amazonaws.cn](https://amazonaws.cn) with its own AK/SK.

### Mode B: IAM Roles Anywhere (recommended for enterprises)

X.509 certificate → Roles Anywhere temporary credentials → Hub AssumeRole → Spoke temporary credentials:

```
Container starts → writes certs to disk → registers credential_process (AWS_CONFIG_FILE)
The SDK invokes credential-helper.sh on demand:
  aws_signing_helper → Hub temp credentials → sts:AssumeRole → Spoke temp credentials
botocore reads Expiration and re-invokes the helper near expiry (lazy refresh, no background threads)
```

- No long-lived keys; a leaked certificate is revocable within seconds via CRL
- One certificate covers all accounts (Hub-Spoke fan-out)
- Detailed setup: **[docs/deploy/DEPLOY-ROLES-ANYWHERE.md](./docs/deploy/DEPLOY-ROLES-ANYWHERE.md)**

---

## Known limitations

| Issue | Current state | Improvement path |
|---|---|---|
| **API key auth not enforced** | The ALB doesn't validate headers; Private Connection network isolation is the backstop | Add an ALB Lambda authorizer or enable OAuth (`AUTH_TYPE=oauth`) |
| **Single NAT Gateway** | single-AZ — a SPOF | one NAT per AZ in production |
| **Alibaba Cloud MCP lacks stateless support** | forced to replicas=1 | wait for upstream `alibaba-cloud-ops-mcp-server` support |
| **Certificate auto-renewal** | public ACM certs renew automatically as long as the DNS validation CNAME stays | do not delete the `_0dcdf890...` CNAME in DNSPod |

---

## Upgrading the MCP Server version

Pinned in `deploy/Dockerfile`:

```dockerfile
RUN pip install --no-cache-dir awslabs.aws-api-mcp-server==1.3.33
```

To upgrade: bump the version → `docker build` → push to ECR → restart the service:

```bash
# ECS path
aws ecs update-service --cluster mcp --service mcp-aws-cn --force-new-deployment

# EKS path
kubectl -n mcp rollout restart deploy/mcp-aws-cn
```

---

## Further reading

- **[docs/deploy/DEPLOY-ROLES-ANYWHERE.md](./docs/deploy/DEPLOY-ROLES-ANYWHERE.md)** —— 🔐 IAM Roles Anywhere zero-key authentication deployment guide
- **[docs/deploy/DEPLOY-RA-RECORD.md](./docs/deploy/DEPLOY-RA-RECORD.md)** —— real deployment log (exact copy-pastable commands)
- **[docs/deploy/REBUILD.md](./docs/deploy/REBUILD.md)** —— runbook for destroying existing resources + rebuilding on the latest code
- **[docs/legacy-eks/SETUP.md](./docs/legacy-eks/SETUP.md)** —— ⚠️ legacy EKS path, complete zero-to-running steps
- **[docs/legacy-eks/MULTI-ACCOUNT.md](./docs/legacy-eks/MULTI-ACCOUNT.md)** —— ⚠️ legacy EKS multi-account scaling & operations
- **[docs/blog/BLOG.md](./docs/blog/BLOG.md)** —— war stories of the 7 biggest pitfalls
- **[MCP protocol specification](https://modelcontextprotocol.io)**
