# 多账号运维指南

本文档描述**如何在这个项目里管理多个 AWS / 阿里云账号**。分两部分：

- **Phase 1（现在可用）**：Helm chart 模板化，每账号一个 release。加账号成本从 ~70 行改动降到 "1 个 values 文件 + 1 条 DNS + 1 个 secret key"。
- **Phase 2（按需启用）**：External Secrets Operator 对接 AWS Secrets Manager，集中管理 + 自动轮换凭证。

架构设计为什么是这样、为什么不是"一个 pod 多账号"、为什么不用 AssumeRole chain —— 参考 [BLOG.md](./BLOG.md) 的"多账号演进思考"章节（TODO）或直接看下面的 FAQ。

---

## 架构

```
                  ┌──── AWS Secrets Manager（Phase 2）────┐
                  │  /mcp/aws-global  = {"AK":...,"SK":...}│
                  │  /mcp/aws-cn      = {"AK":...,"SK":...}│
                  │  /mcp/aws-cn-dev  = {"AK":...,"SK":...}│ ← 加账号从这里
                  └───────────────────┬───────────────────┘
                                      │ ESO 1h 同步
                                      ▼
                     ┌── K8s namespace: mcp ──┐
                     │  Secret mcp-aws-global │  ← Phase 2 由 ESO 创建
                     │  Secret mcp-aws-cn     │     Phase 1 手动建（叫 mcp-creds）
                     └──────┬─────────────────┘
                            │
                            ▼
        Helm release: aws-global         Helm release: aws-cn
        ├── Deployment mcp-aws-global    ├── Deployment mcp-aws-cn
        ├── Service    mcp-aws-global    ├── Service    mcp-aws-cn
        └── Ingress    mcp-aws-global    └── Ingress    mcp-aws-cn
               (group.name: mcp)                (group.name: mcp)
                            │
                            ▼
                  ALB Controller 合并 → 一个 ALB
                            │
                            ▼
                   host-based routing:
                   aws-global.yingchu.cloud → Service mcp-aws-global
                   aws-cn.yingchu.cloud     → Service mcp-aws-cn
```

**关键：** IngressGroup annotation `alb.ingress.kubernetes.io/group.name: mcp` 让所有 account 的 Ingress 合并到一个 ALB。加账号时新建 Ingress 自动并入，**不会产生新 ALB，不需要动 DevOps Agent Private Connection**。

---

## 快速参考：加一个新账号

假设要加 `aws-cn-prod`，流程：

### 1. 凭证
```bash
# Mode A（当前使用）：加到现有 mcp-creds secret
kubectl -n mcp edit secret mcp-creds
# 加 AWS_CN_PROD_AK 和 AWS_CN_PROD_SK 两个 key（base64 编码的 AK/SK）

# Mode B（ESO 启用后）：直接进 Secrets Manager
aws secretsmanager create-secret --region us-east-1 \
  --name /mcp/aws-cn-prod \
  --secret-string '{"AK":"AKIA...","SK":"..."}'
```

### 2. DNS
```bash
ALB=internal-k8s-mcp-mcp-6334395754-126597647.us-east-1.elb.amazonaws.com
ZONE_ID=Z09231282I798DJM5YYUW
aws route53 change-resource-record-sets --hosted-zone-id $ZONE_ID --change-batch "{
  \"Changes\":[{\"Action\":\"UPSERT\",\"ResourceRecordSet\":{
    \"Name\":\"aws-cn-prod.yingchu.cloud\",\"Type\":\"CNAME\",\"TTL\":60,
    \"ResourceRecords\":[{\"Value\":\"$ALB\"}]}}]}"
```

### 3. values 文件

`chart/values-aws-cn-prod.yaml`：
```yaml
account:
  name: aws-cn-prod
  awsRegion: cn-north-1
  host: aws-cn-prod.yingchu.cloud
  # Mode A
  existingSecret: mcp-creds
  secretKeys:
    AWS_ACCESS_KEY_ID: AWS_CN_PROD_AK
    AWS_SECRET_ACCESS_KEY: AWS_CN_PROD_SK
  # Mode B（ESO 启用时）
  secretsManagerKey: /mcp/aws-cn-prod
```

### 4. 部署
```bash
helm upgrade --install aws-cn-prod ./chart -f chart/values-aws-cn-prod.yaml --wait
```

### 5. DevOps Agent 注册
- Console → Capability Providers → MCP Server → Register
- Name: `aws-cn-prod-mcp`
- Endpoint URL: `https://aws-cn-prod.yingchu.cloud/mcp`
- Private connection: **复用现有的 `mcp-alb`**
- Agent Space → Capabilities → MCP Servers → Add → 勾选新的

**端到端验证**：
```bash
# 观察新 pod 日志
kubectl -n mcp logs deploy/mcp-aws-cn-prod -f | grep -v "GET /mcp"
# 然后在 Agent Space 聊天："List EC2 instances in cn-north-1 using aws-cn-prod"
# 日志里会立刻刷出 POST /mcp 200
```

---

## Phase 2：启用 External Secrets Operator

**什么时候启用**：账号数 ≥ 5，或有审计/合规要求（凭证轮换、集中管理、审计日志）。

### 1. 改 Terraform 加 ESO IRSA role

在 `terraform/main.tf` 末尾加：

```hcl
module "eso_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name = "${local.name}-eso"
  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["external-secrets:external-secrets"]
    }
  }
  role_policy_arns = {
    secrets = aws_iam_policy.eso_secrets.arn
  }
}

resource "aws_iam_policy" "eso_secrets" {
  name = "${local.name}-eso-secrets"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
      Resource = "arn:aws:secretsmanager:us-east-1:034362076319:secret:/mcp/*"
    }]
  })
}

output "eso_irsa_role_arn" { value = module.eso_irsa.iam_role_arn }
```

`terraform apply`，记下 `eso_irsa_role_arn`。

### 2. 安装 ESO

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm upgrade --install external-secrets external-secrets/external-secrets \
  -n external-secrets \
  --create-namespace \
  --set installCRDs=true \
  --wait

# 挂 IRSA
kubectl -n external-secrets annotate sa external-secrets \
  eks.amazonaws.com/role-arn=$(terraform -chdir=terraform output -raw eso_irsa_role_arn)
kubectl -n external-secrets rollout restart deploy external-secrets
```

### 3. 把现有凭证搬进 Secrets Manager

```bash
# 从 K8s Secret 读出来（注意删 /tmp 文件）
kubectl -n mcp get secret mcp-creds -o json | python3 -c "
import json, sys, base64
d = json.load(sys.stdin)['data']
for name in ['aws-global', 'aws-cn']:
    prefix = 'AWS_GLOBAL' if name == 'aws-global' else 'AWS_CN'
    print(f'/mcp/{name}:', json.dumps({
        'AK': base64.b64decode(d[f'{prefix}_AK']).decode(),
        'SK': base64.b64decode(d[f'{prefix}_SK']).decode()
    }))
"

# 手工推到 Secrets Manager（逐个）
aws secretsmanager create-secret --region us-east-1 \
  --name /mcp/aws-global --secret-string '{"AK":"...","SK":"..."}'
aws secretsmanager create-secret --region us-east-1 \
  --name /mcp/aws-cn --secret-string '{"AK":"...","SK":"..."}'
```

### 4. 创 ClusterSecretStore

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: aws-secrets-manager
spec:
  provider:
    aws:
      service: SecretsManager
      region: us-east-1
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets
            namespace: external-secrets
EOF
```

### 5. 切换 chart 到 ESO 模式

改每个 `values-*.yaml`，加：
```yaml
externalSecrets:
  enabled: true
  secretStoreName: aws-secrets-manager
```

然后 `helm upgrade --install` 每个 release。Chart 会：
- 渲染 ExternalSecret
- ESO 检测到 → 从 Secrets Manager 拉 → 创建/更新 K8s Secret（名字 `mcp-<account>`）
- Deployment 的 `secretKeyRef` 在 ESO 模式下自动切到这个新 Secret

验证：
```bash
kubectl -n mcp get externalsecret       # STATUS 应该是 SecretSynced
kubectl -n mcp get secret mcp-aws-global -o jsonpath='{.metadata.ownerReferences}'
# 应看到 ExternalSecret 作为 owner
```

### 6. 清理旧 secret

```bash
# 确认 ESO 同步的新 secret 名字不是 mcp-creds（应该是 mcp-aws-global / mcp-aws-cn）
kubectl -n mcp delete secret mcp-creds
```

---

## 从 k8s-2svc.yaml 迁到 Helm chart（有坑）

现在部署用的是 `deploy/k8s-2svc.yaml` 里硬编码的 manifest，**Ingress 不带 `group.name`**。迁 chart 时 Ingress 改用 `group.name: mcp`，但这会触发：

> **⚠️ ALB Controller 会建新 ALB，旧 ALB 被销毁。新 ALB 有不同的 DNS 名，必须更新 DevOps Agent Private Connection 的 Host address。**

### 迁移步骤

```bash
# 1. 看清楚当前 ALB DNS（记下来回滚用）
OLD_ALB=$(kubectl -n mcp get ingress mcp -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "OLD ALB: $OLD_ALB"

# 2. 删旧 Ingress（Deployments 还在，服务不中断 pod 层面；但 ALB 会立刻失效）
kubectl -n mcp delete ingress mcp

# 3. Helm install（chart 会创建新 Ingress，ALB Controller 建新 ALB）
helm upgrade --install aws-global ./chart -f chart/values-aws-global.yaml --wait
helm upgrade --install aws-cn     ./chart -f chart/values-aws-cn.yaml     --wait

# 4. 拿到新 ALB DNS
NEW_ALB=$(kubectl -n mcp get ingress mcp-aws-global -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "NEW ALB: $NEW_ALB"

# 5. 更新 Route53 CNAME（两个 host 都指向新 ALB）
ZONE_ID=Z09231282I798DJM5YYUW
for host in aws-global aws-cn; do
  aws route53 change-resource-record-sets --hosted-zone-id $ZONE_ID --change-batch "{
    \"Changes\":[{\"Action\":\"UPSERT\",\"ResourceRecordSet\":{
      \"Name\":\"${host}.yingchu.cloud\",\"Type\":\"CNAME\",\"TTL\":60,
      \"ResourceRecords\":[{\"Value\":\"$NEW_ALB\"}]}}]}"
done

# 6. 更新 DevOps Agent Private Connection（Console 操作）
#    - 删掉老的 mcp-alb Private Connection
#    - 新建一条，Host address 填 $NEW_ALB
#    - 等 ~10 分钟 Completed
#    - 把两个 MCP Server（aws-cn-mcp、aws-global-mcp）的 Private Connection 切到新的
#    - Agent Space 里重新验证

# 7. 删掉旧 Deployments + Services（chart 已经有新的了）
kubectl -n mcp delete deploy aws-global aws-cn
kubectl -n mcp delete svc aws-global aws-cn

# 8. 端到端验证
kubectl -n mcp logs deploy/mcp-aws-cn -f | grep -v "GET /mcp"
# 在 DevOps Agent 聊天框发测试消息
```

**预期中断时间**：ALB 重建 + DevOps Agent Private Connection 重建 ≈ **15~20 分钟**。选一个业务低峰期做。

**回滚**：
```bash
helm uninstall aws-global aws-cn
kubectl apply -f deploy/k8s-2svc.yaml
# 再 Route53 CNAME 改回旧 ALB DNS（如果还能查到）
# DevOps Agent 这边你得手动恢复 Private Connection
```

---

## FAQ

### 为什么不用"一个 pod 挂所有账号 AK/SK，按请求参数选"？

三个理由：

1. **爆炸半径**：一个 pod 装 N 套 AK/SK → 一次容器逃逸 / 代码注入 / 依赖漏洞 → **全账号泄露**。
2. **aws-api-mcp-server 不支持**：它是进程级凭证（boto3 读环境变量），不是请求级。并发切 env var 会有竞态。要实现得 fork 源码。
3. **DevOps Agent 还是要注册 N 个**：就算 pod 内部能路由，DevOps Agent 按工具名/意图选 MCP，你还是得每个账号 Register 一次 MCP Server。省的只是 pod 数量。

### 为什么不用 AssumeRole chain？

这是 AWS 标准多账号模式，但：
- AWS **全球区 ↔ 中国区 partition 隔离**，不能跨 AssumeRole。每个 partition 都要独立 hub role。
- aws-api-mcp-server 不支持"按请求换 role"，需要 fork 或写 sidecar 代理 STS 调用。
- **阿里云完全走不通**（不是 AWS）。

适合 15+ 账号时再投入。当前规模下用 Phase 2 的 Secrets Manager 方案即可。

### 阿里云怎么接？

等 `alibaba-cloud-ops-mcp-server` 和 `awslabs.aws-api-mcp-server` 的 `fastmcp` 版本冲突解决，或者：

1. 建独立镜像 `deploy/Dockerfile.aliyun`，`FROM public.ecr.aws/docker/library/python:3.12-slim` + `pip install alibaba-cloud-ops-mcp-server==X.Y.Z`
2. Chart 的 `image.repository` 和 `mcpServer.command` 做成 per-values 覆盖（已经支持，见 `account.extraEnv` 和 mcpServer 部分）
3. 阿里云的认证走 `ALIBABA_CLOUD_ACCESS_KEY_ID` 和 `ALIBABA_CLOUD_ACCESS_KEY_SECRET`，chart 的 deployment 模板里的 env 需要改（或者把 env 全改成 `extraEnv` 驱动，不写死 AWS 前缀）

### ESO 同步间隔能改吗？

`values.yaml` 里：
```yaml
externalSecrets:
  refreshInterval: 1h    # 改成 15m / 5m / 30s 任意 Go duration 格式
```

越短 API 调用越多，Secrets Manager 每次调用 $0.05/10000。1h 间隔 10 个账号一天 24*10=240 次，几乎免费。

### 新账号加完了 DevOps Agent 那边忘了 Add 会怎样？

参考 [BLOG.md 坑 7](./BLOG.md) —— Agent 会 fallback 到内置 `use_aws` 工具，用控制台登录态凭证调用，pod 日志里完全看不到流量。现象隐蔽但可以通过 `kubectl logs` 有没有 `POST /mcp 200` 来判断是否真的用上你的 MCP。

---

## 相关文档

- [README.md](./README.md) —— 项目总览
- [SETUP.md](./SETUP.md) —— 从零部署步骤
- [BLOG.md](./BLOG.md) —— 踩坑记录
- [chart/README.md](./chart/README.md) —— Helm chart 用法
