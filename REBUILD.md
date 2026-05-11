# 从零重建：完整拆除 + 重部署 Runbook

这个 runbook 是**彻底清场后按仓库最新代码重建**。目标：

- 验证 `SETUP.md` + `MULTI-ACCOUNT.md` + `chart/` + `chart-aliyun/` 从空账户开始真能跑通
- 收获一套干净的、"仓库即真相"的部署（消除历史 drift）
- 直接走 **Mode B（ESO + Secrets Manager）**，省掉一次性的 Mode A→B 迁移

## 前置决策（已确认）

- ✅ **保留** ACM 通配符证书 `*.yingchu.cloud`（ARN 在 CLAUDE.md 里）
- ✅ **保留** ECR 仓库 `aws-devops-agent-external-mcp` 和 `mcp-aliyun`（如果有）
- ✅ **直接 Mode B**（ESO + Secrets Manager）
- ✅ **先跑通 aws-cn，再补 aws-global**（中国区是独立 partition，上次踩坑最多，优先验证这条链路；全球区确定性更高，作为第二批快速复制）

## 预计耗时

| 阶段 | 时长 | 主要时间花在 |
|---|---|---|
| Teardown | ~30 分钟 | `terraform destroy`（~15min）+ DevOps Agent 手工删除 |
| Rebuild | ~60 分钟 | `terraform apply`（~20min）+ Private Connection provisioning（10min）+ 其他 |
| **总计** | **~90 分钟** | 大部分是等 AWS 资源 provision |

建议安排一个**整 2 小时空档**（留 30min 应对意外）。业务使用 DevOps Agent 的团队要提前通知。

## 当前资源清单（要删的）

在开始前，这是目前账号里活着的 MCP 相关资源 —— 参考用，具体 ID 以命令输出为准：

| 类型 | 标识 |
|---|---|
| EKS Cluster | `mcp-test` |
| VPC | `vpc-033d9e9955afde81f` |
| ALB | `internal-k8s-mcp-mcp-6334395754-126597647.us-east-1.elb.amazonaws.com` |
| Route53 私有 Zone | `yingchu.cloud` (Z09231282I798DJM5YYUW)，`mcp.internal` (Z0836957CF7T4CZOXX3K) |
| K8s namespace `mcp` | Deployments aws-global / aws-cn；Secret mcp-creds |
| DevOps Agent | Private Connection `mcp-alb`（也许还有 `test-devops-agent`、`mcp-eks`、`mcp-yingchu` 等失败尝试的残留），2 个 MCP Server 注册 |
| ACM 证书 | `*.yingchu.cloud`（**保留**），`*.mcp.internal` 自签（可删）|

---

## Part 1 — Teardown

### Step 1.1 DevOps Agent（Console 手工）

控制台没有 CLI 批量操作（你那版 aws CLI 2.32 没有 `aws devops-agent` 子命令；2.36+ 有，可以 `brew upgrade awscli`）。

**建议顺序**（从外往内拆，否则会报"被引用"错）：

1. **Agent Space** → Capabilities → MCP Servers → 找 `aws-cn-mcp` 和 `aws-global-mcp`（或你命名的）→ Remove / 取消勾选
2. **Capability Providers** → MCP Server → 每个注册项都 Delete
3. **Capability Providers** → Private connections → 逐个 Delete
   - `mcp-alb` / `mcp-eks` / `mcp-yingchu` / `mcp-test-no-cert` / `test-devops-agent` 全删
   - 每条 Private Connection deletion 约 2-5 分钟（等 VPC Lattice Resource Gateway 清理）

⚠️ **关键**：Private Connection 必须在 `terraform destroy` 之前删完！否则 VPC Lattice Resource Gateway 会卡住 VPC 删除流程。

### Step 1.2 Kubernetes

```bash
export AWS_PROFILE=default
cd /Users/ychchen/warren_ws/aws-devops-agent-external-mcp

# 删 k8s 层资源（现有运行的是 k8s-2svc.yaml 版本）
kubectl delete -f deploy/k8s-2svc.yaml

# 如果装了 ALB Controller，下一步 terraform destroy 会卡。先 uninstall：
helm uninstall aws-load-balancer-controller -n kube-system
# 等 30 秒让它清理 TargetGroupBinding 等 CRD 资源
sleep 30

# 如果装了 ESO（这次清理可能没，但防万一）
helm uninstall external-secrets -n external-secrets 2>/dev/null || echo "ESO not installed, skipping"
```

### Step 1.3 Route53 私有 zone

```bash
# yingchu.cloud 私有 zone：删所有非 NS/SOA 记录 → 再删 zone
ZONE=Z09231282I798DJM5YYUW
aws route53 list-resource-record-sets --hosted-zone-id $ZONE \
  --query 'ResourceRecordSets[?Type!=`NS` && Type!=`SOA`]' > /tmp/records.json

python3 -c "
import json
recs = json.load(open('/tmp/records.json'))
if not recs: exit()
batch = {'Changes': [{'Action': 'DELETE', 'ResourceRecordSet': r} for r in recs]}
json.dump(batch, open('/tmp/delete-batch.json', 'w'))
"
aws route53 change-resource-record-sets --hosted-zone-id $ZONE --change-batch file:///tmp/delete-batch.json
aws route53 delete-hosted-zone --id $ZONE

# 同理 mcp.internal（如果还在）
ZONE=Z0836957CF7T4CZOXX3K
# 重复上面的过程
```

### Step 1.4 Secrets Manager（Mode B 残留）

```bash
# 如果之前试过把凭证放 Secrets Manager，现在清理：
for key in /mcp/aws-global /mcp/aws-cn; do
  aws secretsmanager delete-secret --region us-east-1 \
    --secret-id $key \
    --force-delete-without-recovery 2>/dev/null || echo "$key: not found"
done
```

### Step 1.5 Terraform destroy

```bash
cd terraform
terraform init    # 确保 providers / modules 就位

# 先看 destroy 计划，确认没意外
terraform plan -destroy -no-color | tail -20

# 真拆
terraform destroy -auto-approve
# 等 15-20 分钟。大头是 EKS cluster deletion。
```

⚠️ **如果 destroy 卡住** 常见原因：
- 有残留 LoadBalancer Service 导致 ALB 没清理 → 回 Step 1.2 确认 ALB Controller 已 uninstall 且没有 TargetGroupBinding
- Private Connection 还在 → 回 Step 1.1 确认都删了
- 找不到资源但 state 里有 → 用 `terraform state rm <address>` 移除孤儿记录

如果真卡死，终极手段：手工到 AWS Console 删除 VPC / EKS / 关联资源，然后：
```bash
rm terraform.tfstate terraform.tfstate.backup
```
让后续 `terraform apply` 从干净 state 起步。

### Step 1.6（可选）自签证书清理

保留 ACM 公共证书。自签的可以清：
```bash
# 老的自签证书（*.mcp.internal）
aws acm delete-certificate --region us-east-1 \
  --certificate-arn arn:aws:acm:us-east-1:034362076319:certificate/fa6453c0-f48a-4b60-b31d-aa72ed596e0e 2>/dev/null || true
aws acm delete-certificate --region us-east-1 \
  --certificate-arn arn:aws:acm:us-east-1:034362076319:certificate/596d8627-7826-4c4f-b160-2c857688eea4 2>/dev/null || true
```

### Step 1.7 验证清场

```bash
aws eks list-clusters --region us-east-1
# 期望：不含 mcp-test

aws ec2 describe-vpcs --region us-east-1 --filters "Name=tag:Name,Values=mcp-test" --query 'Vpcs[].VpcId' --output text
# 期望：空

aws route53 list-hosted-zones --query 'HostedZones[?contains(Name, `mcp.internal`) || contains(Name, `yingchu.cloud`) && Config.PrivateZone==`true`].Name' --output text
# 期望：空

aws secretsmanager list-secrets --region us-east-1 --query 'SecretList[?starts_with(Name, `/mcp/`)].Name' --output text
# 期望：空
```

---

## Part 2 — Rebuild（直接 Mode B）

### Step 2.1 Terraform apply

```bash
cd terraform
terraform apply -auto-approve
# ~15-20 分钟。创建 VPC + NAT + EKS + LBC IRSA + ESO IRSA。

# 拿输出
terraform output
```

记下：
- `cluster_name`: `mcp-test`
- `vpc_id`: `vpc-xxxxxxxx`（新的！要更新 CLAUDE.md 里的 VPC 注释）
- `private_subnets`: 两个新 subnet ID
- `lb_controller_role_arn`
- `eso_irsa_role_arn`

```bash
# 更新 kubeconfig
$(terraform output -raw kubeconfig_cmd)

# 验证连接
kubectl get nodes
```

### Step 2.2 装 ALB Controller

```bash
helm repo add eks https://aws.github.io/eks-charts
helm repo update

helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=$(terraform -chdir=terraform output -raw cluster_name) \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=$(terraform -chdir=terraform output -raw lb_controller_role_arn) \
  --set region=us-east-1 \
  --set vpcId=$(terraform -chdir=terraform output -raw vpc_id) \
  --wait

# 验证
kubectl -n kube-system get deploy aws-load-balancer-controller
```

### Step 2.3 装 ESO + 配 IRSA

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm repo update

helm upgrade --install external-secrets external-secrets/external-secrets \
  -n external-secrets \
  --create-namespace \
  --set installCRDs=true \
  --wait

# 挂 IRSA（关键）
kubectl -n external-secrets annotate sa external-secrets \
  eks.amazonaws.com/role-arn=$(terraform -chdir=terraform output -raw eso_irsa_role_arn)

# 重启让 pod 拿到新 annotation
kubectl -n external-secrets rollout restart deploy external-secrets
kubectl -n external-secrets rollout status deploy external-secrets --timeout=120s
```

### Step 2.4 创 ClusterSecretStore

```bash
kubectl apply -f deploy/cluster-secret-store.yaml

# 等几秒钟
sleep 5
kubectl get clustersecretstore aws-secrets-manager
# STATUS 应该是 Valid
```

⚠️ 如果 STATUS 不是 Valid，看 Reason。常见错误：
- `InvalidSignatureException` → IRSA annotation 没挂对 / pod 没重启
- `AccessDenied` → IAM policy 范围错了（查 terraform/main.tf 里的 Resource ARN）

### Step 2.5 把 AK/SK 推进 Secrets Manager

**测试优先级：先 aws-cn（中国区 partition 独立认证，上次踩坑多，先验证这条链路）。全球区作为第二批。**

```bash
# ⚠️ 先把 shell history 关了，别让 AK/SK 落到磁盘
export HISTFILE=/dev/null

# --- 中国区（优先） ---
AWS_CN_AK="AKIA..."     # 从 amazonaws.cn 账号里拿（独立 partition）
AWS_CN_SK="..."

aws secretsmanager create-secret --region us-east-1 \
  --name /mcp/aws-cn \
  --secret-string "{\"AK\":\"$AWS_CN_AK\",\"SK\":\"$AWS_CN_SK\"}"

# 验证能读到
aws secretsmanager get-secret-value --region us-east-1 --secret-id /mcp/aws-cn \
  --query SecretString --output text | python3 -m json.tool

# --- 全球区（第二批，跑通中国区后再来） ---
# AWS_GLOBAL_AK="AKIA..."
# AWS_GLOBAL_SK="..."
# aws secretsmanager create-secret --region us-east-1 \
#   --name /mcp/aws-global \
#   --secret-string "{\"AK\":\"$AWS_GLOBAL_AK\",\"SK\":\"$AWS_GLOBAL_SK\"}"
```

### Step 2.6 Route53 私有 zone

```bash
VPC_ID=$(terraform -chdir=terraform output -raw vpc_id)

ZONE_RESP=$(aws route53 create-hosted-zone \
  --name yingchu.cloud \
  --caller-reference "mcp-$(date +%s)" \
  --vpc VPCRegion=us-east-1,VPCId=$VPC_ID \
  --hosted-zone-config PrivateZone=true,Comment="MCP on EKS private zone")

ZONE_ID=$(echo "$ZONE_RESP" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['HostedZone']['Id'].split('/')[-1])")
echo "ZONE_ID=$ZONE_ID    # 记下，下面要用"
```

### Step 2.7 切换 chart 到 Mode B + Helm install（先装 aws-cn）

编辑 `chart/values-aws-cn.yaml`（第一批只改这个，aws-global 待 cn 验证通过后再处理）：

```yaml
# 加到 values-aws-cn.yaml 末尾（或在 --set 里传）
externalSecrets:
  enabled: true
  secretStoreName: aws-secrets-manager

# 确保 account.secretsManagerKey=/mcp/aws-cn 已填（values-aws-cn.yaml 默认就有）
# existingSecret/secretKeys 在 Mode B 下被忽略，不用删
```

```bash
# 只部署中国区这一个 release
helm upgrade --install aws-cn ./chart -f chart/values-aws-cn.yaml --wait

# 验证 ESO 同步工作
kubectl -n mcp get externalsecret
# STATUS 应该是 SecretSynced

kubectl -n mcp get secret mcp-aws-cn
# 应该存在，由 ESO 创建

# pod 状态
kubectl -n mcp get pods
# 2 副本 Running，0 restarts
```

⚠️ 如果 ExternalSecret `STATUS=ERROR`：
- `kubectl -n mcp describe externalsecret mcp-aws-cn` 看 events
- 常见：IRSA annotation 没生效（回 Step 2.3）/ Secrets Manager key 拼写错 / JSON 格式错（必须是 `{"AK":"...","SK":"..."}`）

### Step 2.8 添 DNS CNAME（先 aws-cn）

```bash
ALB=$(kubectl -n mcp get ingress mcp-aws-cn -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "NEW ALB: $ALB"

# 确认公网能查到 ALB（重要！Private Connection Host address 要求公网可解析）
dig +short @8.8.8.8 $ALB
# 期望：返回私有 IP（10.42.x.x）

# 只加 aws-cn 的 CNAME（第一批）
aws route53 change-resource-record-sets --hosted-zone-id $ZONE_ID --change-batch "{
  \"Changes\":[{\"Action\":\"UPSERT\",\"ResourceRecordSet\":{
    \"Name\":\"aws-cn.yingchu.cloud\",\"Type\":\"CNAME\",\"TTL\":60,
    \"ResourceRecords\":[{\"Value\":\"$ALB\"}]}}]}"
```

### Step 2.9 端到端验证 aws-cn（集群内）

```bash
# 等 ~1 分钟让 ALB 反映新 Ingress 规则
sleep 60

# target group 健康
for tg in $(aws elbv2 describe-target-groups --region us-east-1 --query "TargetGroups[?contains(TargetGroupName, \`mcp\`)].TargetGroupArn" --output text); do
  state=$(aws elbv2 describe-target-health --region us-east-1 --target-group-arn "$tg" --query 'TargetHealthDescriptions[].TargetHealth.State' --output text)
  echo "  $(echo $tg | awk -F/ '{print $(NF-1)}'): $state"
done
# 期望全部 healthy

# 从 pod 里 curl aws-cn endpoint
kubectl -n mcp run curl-verify --rm -i --image=curlimages/curl --restart=Never -q -- sh -c \
'curl -sS -m 10 -X POST https://aws-cn.yingchu.cloud/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"clientInfo\":{\"name\":\"v\",\"version\":\"0\"}}}" \
  -w "\nHTTP:%{http_code} / cert_verify=%{ssl_verify_result}\n"'
# 期望：HTTP:200 / cert_verify=0，且 serverInfo 出现在响应里
```

### Step 2.10 DevOps Agent 配置（先配 aws-cn）

Console 手工：

1. **Capability Providers → Private connections → Create a new connection**
   - Name: `mcp-alb`
   - VPC: 新 VPC ID（terraform output 里的）
   - Subnets: 两个 private subnet（terraform output 里的）
   - Security groups: ALB 的 SG（AWS Console 查新 ALB，或 `kubectl -n mcp get ingress mcp-aws-cn -o yaml | grep -A2 securityGroups`）
   - **Host address**: `$ALB`（Step 2.8 那个值，ALB 的 AWS DNS 名，**不是 yingchu.cloud 域名**）
   - **Certificate public key**: **留空**（ACM 公共证书，默认信任）
   - 点 Create，等 ~10 分钟 `Completed`

2. **MCP Server → Register**（第一批只注册 aws-cn）：
   - Name: `aws-cn-mcp`
   - Endpoint URL: `https://aws-cn.yingchu.cloud/mcp`
   - Private connection: `mcp-alb`
   - Authorization: API Key + dummy 值

3. **Agent Space → Capabilities → MCP Servers → Add**
   - 勾选 `aws-cn-mcp` → Allow all tools → Save

### Step 2.11 最终验证 aws-cn

Agent Space 聊天：
```
List EC2 instances in cn-north-1
```

期望：
- 工具名带 MCP 前缀（类似 `aws-cn-mcp___use_aws`，**不是**光秃秃的 `use_aws`）
- `kubectl -n mcp logs deploy/mcp-aws-cn -f | grep -v "GET /mcp"` 出现 `POST /mcp HTTP/1.1" 200`
- 返回值里的 EC2 列表对应你 `AWS_CN_AK` 的账号 —— **注意中国区账号 ID 跟全球区完全不同的那种** `cn-*` 或独立的 12 位数字
- 不是全球区的 `034362076319`（如果是说明 DevOps Agent 又 fallback 到内置 `use_aws` 了）

✅ 中国区跑通了说明整条链路成功。这一轮最"不确定"的部分已经验证。

### Step 2.12 再把 aws-global 补上（第二批）

中国区验证通过后，复制相同流程给全球区：

```bash
# 1. Secrets Manager
aws secretsmanager create-secret --region us-east-1 \
  --name /mcp/aws-global \
  --secret-string "{\"AK\":\"$AWS_GLOBAL_AK\",\"SK\":\"$AWS_GLOBAL_SK\"}"

# 2. 切 Mode B（编辑 values-aws-global.yaml 加 externalSecrets.enabled=true）
helm upgrade --install aws-global ./chart -f chart/values-aws-global.yaml --wait

# 3. 加 Route53 CNAME
aws route53 change-resource-record-sets --hosted-zone-id $ZONE_ID --change-batch "{
  \"Changes\":[{\"Action\":\"UPSERT\",\"ResourceRecordSet\":{
    \"Name\":\"aws-global.yingchu.cloud\",\"Type\":\"CNAME\",\"TTL\":60,
    \"ResourceRecords\":[{\"Value\":\"$ALB\"}]}}]}"

# 4. pod 日志观察
kubectl -n mcp logs deploy/mcp-aws-global -f | grep -v "GET /mcp"
```

DevOps Agent Console：
- MCP Server → Register `aws-global-mcp` / URL `https://aws-global.yingchu.cloud/mcp` / **复用 `mcp-alb`**
- Agent Space → Capabilities → MCP Servers → Add `aws-global-mcp`

验证：
```
List EC2 instances in us-east-1
```

期望返回 `AWS_GLOBAL_AK` 对应账号的实例。

---

## 出错了怎么回滚

任何一步失败 → 对应的补救：

| 失败的步骤 | 补救 |
|---|---|
| Step 1.5 terraform destroy 卡住 | 手工 AWS Console 删资源 + `terraform state rm` 清 orphan |
| Step 2.1 terraform apply 失败 | 看报错，常见是 EKS 版本（改 `cluster_version`）或 quota |
| Step 2.3 ESO pod 起不来 | `kubectl -n external-secrets describe pod` 看 events，基本是 IRSA annotation 写错 |
| Step 2.4 ClusterSecretStore not Valid | IAM policy 范围（在 `terraform/main.tf` 里确认 `/mcp/*`） |
| Step 2.7 ExternalSecret 状态 ERROR | `kubectl -n mcp describe externalsecret mcp-aws-global` 看 events |
| Step 2.8 CNAME 公网不可解析 | 别惊慌，是 ALB 的 AWS DNS 名（不是你的 yingchu 域），本来就公网可查。你查的是 `aws-cn.yingchu.cloud` 吗？这个只有**私网**能查 |
| Step 2.10 DevOps Agent 注册 ValidationException | 100% 是 Host address 填错了 —— 要填 **ALB 的 AWS DNS 名**，不是 yingchu.cloud 域名。参考 BLOG.md 坑 #5 |

终极回滚：已经走到 2.x 但想放弃 → 整个 `helm uninstall aws-global aws-cn external-secrets aws-load-balancer-controller` + `terraform destroy` 回到 Part 1 的起点。

---

## 和上次部署相比的改进

| 维度 | 上次（k8s-2svc.yaml）| 这次重建 |
|---|---|---|
| 部署 | 硬编码 YAML | Helm chart，加新账号 O(1) |
| 凭证 | K8s Secret 手建 | Secrets Manager + ESO 自动同步 + 支持轮换 |
| 证书 | 从自签走到公共 | 直接用公共 ACM 证书 |
| EKS 节点 | 部署在 public subnet | 部署在 private subnet + NAT |
| ALB | 独立，没 group.name | 带 IngressGroup，加账号时自动合并 |
| 文档 | 零散 | SETUP / BLOG / MULTI-ACCOUNT / REBUILD 四件套 |

这次完成后，**加第 3 个账号就是 4 步**：推 Secret Manager + 写 values.yaml + helm install + DevOps Agent 注册。几分钟的事。
