# mcp-server Helm chart

每个 AWS / 阿里云账号一个 Helm release。所有 release 共享同一个 ALB（靠 IngressGroup 合并）。

## 安装

```bash
# 现有 2 个账号
helm upgrade --install aws-global ./chart -f chart/values-aws-global.yaml --wait
helm upgrade --install aws-cn     ./chart -f chart/values-aws-cn.yaml     --wait
```

## 加一个新账号

1. **凭证**：把新 AK/SK 写进 K8s Secret `mcp-creds`（或开 ESO 后写进 Secrets Manager `/mcp/<name>`）
2. **DNS**：Route53 私有 zone 加 CNAME `<name>.example.cloud → ALB`
3. **values 文件**：复制 `chart/values-aws-cn.yaml`，改 4 个字段 —— `name / awsRegion / host / secretKeys` 或 `secretsManagerKey`
4. **部署**：`helm upgrade --install <name> ./chart -f chart/values-<name>.yaml --wait`
5. **注册**：DevOps Agent 控制台 Register MCP Server + Agent Space Add

## values 字段速查

| 字段 | 必填 | 示例 | 说明 |
|---|---|---|---|
| `account.name` | ✅ | `aws-cn-prod` | 资源命名前缀 |
| `account.awsRegion` | ✅ | `cn-north-1` | boto3 默认区域 |
| `account.host` | ✅ | `aws-cn-prod.example.cloud` | Ingress host 匹配值 + MCP 的 allowed-hosts |
| `account.existingSecret` | Mode A ✅ | `mcp-creds` | 复用的 K8s Secret 名 |
| `account.secretKeys.AWS_ACCESS_KEY_ID` | Mode A ✅ | `AWS_CN_PROD_AK` | Secret 里对应 key 名 |
| `account.secretsManagerKey` | Mode B ✅ | `/mcp/aws-cn-prod` | Secrets Manager key path |
| `account.extraEnv` | ⚪ | `[{name: X, value: Y}]` | 追加环境变量 |
| `replicaCount` | ⚪ | `2`（默认）| 副本数。stateless HTTP 已启用，多副本安全 |
| `auth.mode` | ⚪ | `ak_sk`（默认）/ `roles_anywhere` | 认证模式。够中国区账号选 `roles_anywhere` |
| `rolesAnywhere.trustAnchorArn` | RA ✅ | `arn:aws-cn:rolesanywhere:...:trust-anchor/x` | Hub 的 Trust Anchor ARN |
| `rolesAnywhere.profileArn` | RA ✅ | `arn:aws-cn:rolesanywhere:...:profile/y` | Hub 的 Profile ARN |
| `rolesAnywhere.hubRoleArn` | RA ✅ | `arn:aws-cn:iam::HUB:role/mcp-roles-anywhere-hub` | Hub Role ARN |
| `rolesAnywhere.spokeRoleArn` | RA ✅ | `arn:aws-cn:iam::SPOKE:role/mcp-spoke-readonly` | 要 assume 的 Spoke Role |
| `rolesAnywhere.region` | RA ✅ | `cn-northwest-1` | **Hub 区域**（RA endpoint + AssumeRole），可与 `account.awsRegion` 不同 |
| `rolesAnywhere.externalId` | ⚪ | `mcp-bridge`（默认）| AssumeRole 的 ExternalId，需与 Spoke trust policy 一致 |
| `rolesAnywhere.certSecretsManagerKey` | RA+ESO ✅ | `/mcp/ra-cert-bundle` | 证书 bundle 的 Secrets Manager key |

## Mode A vs Mode B

- **Mode A**（`externalSecrets.enabled=false`，默认）：你手动管 K8s Secret。简单，适合起步。
- **Mode B**（`externalSecrets.enabled=true`）：Chart 渲染 ExternalSecret，ESO 从 Secrets Manager 同步。需要先装 ESO + 配 ClusterSecretStore。详见 [../docs/legacy-eks/SETUP.md](../docs/legacy-eks/SETUP.md) "ESO" 章节。

## auth.mode：AK/SK vs Roles Anywhere

`auth.mode` 决定 MCP Server 怎么拿目标账号的 AWS 凭证，跟上面的 Mode A/B（证书/密钥从哪同步）是**两个正交的维度**。

| | `ak_sk`（默认） | `roles_anywhere` |
|---|---|---|
| 凭证 | 长期 AK/SK | X.509 证书 → Hub 临时凭证 → AssumeRole 进 Spoke |
| 适合 | 全球区账号本身、阿里云 | **全球区集群够中国区账号** |
| 镜像 | `Dockerfile` | `Dockerfile.ra`（含 `aws_signing_helper`） |
| 证书投递 | — | ESO → K8s Secret → **只读 volume 挂载**（不进环境变量） |

> **为什么够中国区必须用 Roles Anywhere**：EKS 集群跑在全球区（`aws` 分区）。即使用 IRSA 给 Pod 一个全球区 Role，它也**不能跨分区 AssumeRole** 进 `aws-cn`。Roles Anywhere 让证书在中国区 Hub 换出 `aws-cn` 分区的临时凭证，再在分区内 AssumeRole 扇出到各 Spoke。完整原理见 [../docs/deploy/DEPLOY-ROLES-ANYWHERE.md](../docs/deploy/DEPLOY-ROLES-ANYWHERE.md)。

### 用 Roles Anywhere 部署一个中国区账号

前置：Hub/Spoke 的 CFN 已部署（见上面那份文档），镜像用 `Dockerfile.ra` 构建并推到 ECR。

1. **证书 bundle 进 Secrets Manager**（JSON 格式，cert/key 各一个 PEM）：
   ```bash
   aws secretsmanager create-secret --name /mcp/ra-cert-bundle --region us-east-1 \
     --secret-string "$(jq -n --arg c "$(cat ~/mcp-certs/client.crt)" \
                              --arg k "$(cat ~/mcp-certs/client.key)" \
                              '{cert:$c, key:$k}')"
   ```
   > 注意：ECS 路径把 cert/key 存成两个独立 secret；EKS 这里合成**一个 bundle**，更适配 ESO 的 `property` 拆分（一个 ExternalSecret 拆出 `client.crt` + `client.key` 两个文件）。

2. **复制示例 values**：`chart/values-aws-cn-ra.yaml` 已是完整模板，填入 Hub/Spoke 的 ARN + `region` + `certSecretsManagerKey`。

3. **部署**：
   ```bash
   helm upgrade --install aws-cn ./chart -f chart/values-aws-cn-ra.yaml --wait
   ```

4. **验证**：
   ```bash
   kubectl -n mcp logs deploy/mcp-aws-cn | grep entrypoint-ra
   # 期望: [entrypoint-ra] Initial credential fetch OK.
   ```

### 从 AK/SK 迁移到 Roles Anywhere

两种模式可以按账号混用（一个 release 一种），无需一刀切。把某账号的 values 从 `values-aws-cn.yaml` 换成 `values-aws-cn-ra.yaml` 风格、`helm upgrade` 即可滚动切换。推荐顺序：生产账号优先（安全收益最大）→ 验证稳定 → 迁其余。

## 验证

```bash
helm template <release> ./chart -f chart/values-<release>.yaml    # 本地渲染看结果
helm upgrade --install <release> ./chart -f chart/values-<release>.yaml --dry-run    # 服务端验证
```

## 卸载

```bash
helm uninstall <release>
```

Namespace `mcp` 只有最后一个 release 删除时才会走（因为每个 release 都声明了这个 Namespace）。实际不删 namespace 也无妨。
