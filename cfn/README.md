# IAM Roles Anywhere — Zero-AK/SK Authentication

Replaces long-lived AK/SK with X.509 certificate-based temporary credentials.

## Architecture

```
MCP Server (us-east-1 ECS)
    │
    │ X.509 client cert
    ▼
Roles Anywhere (cn-northwest-1, Hub Account)
    │
    │ Hub temporary credentials
    ▼
sts:AssumeRole (ExternalId=mcp-bridge)
    │
    ├──→ Spoke Account A  (cn-northwest-1)  ReadOnlyAccess
    ├──→ Spoke Account B  (cn-north-1)      ReadOnlyAccess
    └──→ Spoke Account C  (cn-northwest-1)  Custom Policy
```

## Setup Steps

### 1. Generate certificates

```bash
./generate-certs.sh ~/mcp-certs
```

### 2. Deploy Hub stack (once, in the central China account)

```bash
aws cloudformation deploy \
  --template-file roles-anywhere-hub.yaml \
  --stack-name mcp-roles-anywhere-hub \
  --parameter-overrides \
    CACertificateBody="$(cat ~/mcp-certs/ca.crt)" \
    SpokeRoleArns="arn:aws-cn:iam::222:role/mcp-spoke-readonly,arn:aws-cn:iam::333:role/mcp-spoke-readonly" \
  --capabilities CAPABILITY_NAMED_IAM \
  --region cn-northwest-1 \
  --profile china-hub
```

### 3. Deploy Spoke stack (in each target account)

```bash
# Get Hub Role ARN from step 2
HUB_ROLE_ARN=$(aws cloudformation describe-stacks \
  --stack-name mcp-roles-anywhere-hub \
  --region cn-northwest-1 --profile china-hub \
  --query 'Stacks[0].Outputs[?OutputKey==`HubRoleArn`].OutputValue' --output text)

# Deploy in spoke account
aws cloudformation deploy \
  --template-file roles-anywhere-spoke.yaml \
  --stack-name mcp-spoke-role \
  --parameter-overrides HubRoleArn="$HUB_ROLE_ARN" \
  --capabilities CAPABILITY_NAMED_IAM \
  --region cn-northwest-1 \
  --profile china-spoke-a
```

### 4. Store cert/key in Secrets Manager (in the ECS account, us-east-1)

```bash
aws secretsmanager create-secret \
  --name /mcp/ra-cert \
  --secret-string file://~/mcp-certs/client.crt \
  --region us-east-1

aws secretsmanager create-secret \
  --name /mcp/ra-key \
  --secret-string file://~/mcp-certs/client.key \
  --region us-east-1
```

### 5. Update terraform.tfvars

```hcl
roles_anywhere = {
  cert_secret_arn  = "arn:aws:secretsmanager:us-east-1:<GLOBAL_ACCOUNT_ID>:secret:/mcp/ra-cert-XXXXXX"
  key_secret_arn   = "arn:aws:secretsmanager:us-east-1:<GLOBAL_ACCOUNT_ID>:secret:/mcp/ra-key-XXXXXX"
  trust_anchor_arn = "arn:aws-cn:rolesanywhere:cn-northwest-1:111:trust-anchor/..."
  profile_arn      = "arn:aws-cn:rolesanywhere:cn-northwest-1:111:profile/..."
  hub_role_arn     = "arn:aws-cn:iam::111:role/mcp-roles-anywhere-hub"
  region           = "cn-northwest-1"
}

accounts = {
  aws-cn = {
    host           = "aws-cn.example.cloud"
    aws_region     = "cn-northwest-1"
    auth_mode      = "roles_anywhere"
    spoke_role_arn = "arn:aws-cn:iam::111:role/mcp-spoke-readonly"
  }
}
```

### 6. Build and deploy

```bash
# Build with Roles Anywhere support
docker build -t <ecr_url>:latest -f deploy/Dockerfile.ra .
docker push <ecr_url>:latest
terraform apply
```

## Adding a new spoke account

1. Deploy `roles-anywhere-spoke.yaml` in the new account
2. Update Hub stack's `SpokeRoleArns` parameter to include the new role ARN
3. Add entry to `accounts` in terraform.tfvars
4. `terraform apply`

## Certificate rotation

1. Generate new client cert with existing CA: `openssl req -new ...` + `openssl x509 -req ...`
2. Update Secrets Manager: `aws secretsmanager update-secret-value --secret-id /mcp/ra-cert --secret-string file://new-client.crt`
3. Force ECS redeployment: `aws ecs update-service --force-new-deployment ...`

No changes needed in IAM Roles Anywhere — the Trust Anchor trusts the CA, not individual certs.

## Revoking access

- **Single cert**: Add serial number to CRL, upload to Trust Anchor
- **Single spoke**: Delete the spoke CloudFormation stack
- **All access**: Disable the Trust Anchor in IAM Roles Anywhere console
