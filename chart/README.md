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
2. **DNS**：Route53 私有 zone 加 CNAME `<name>.yingchu.cloud → ALB`
3. **values 文件**：复制 `chart/values-aws-cn.yaml`，改 4 个字段 —— `name / awsRegion / host / secretKeys` 或 `secretsManagerKey`
4. **部署**：`helm upgrade --install <name> ./chart -f chart/values-<name>.yaml --wait`
5. **注册**：DevOps Agent 控制台 Register MCP Server + Agent Space Add

## values 字段速查

| 字段 | 必填 | 示例 | 说明 |
|---|---|---|---|
| `account.name` | ✅ | `aws-cn-prod` | 资源命名前缀 |
| `account.awsRegion` | ✅ | `cn-north-1` | boto3 默认区域 |
| `account.host` | ✅ | `aws-cn-prod.yingchu.cloud` | Ingress host 匹配值 + MCP 的 allowed-hosts |
| `account.existingSecret` | Mode A ✅ | `mcp-creds` | 复用的 K8s Secret 名 |
| `account.secretKeys.AWS_ACCESS_KEY_ID` | Mode A ✅ | `AWS_CN_PROD_AK` | Secret 里对应 key 名 |
| `account.secretsManagerKey` | Mode B ✅ | `/mcp/aws-cn-prod` | Secrets Manager key path |
| `account.extraEnv` | ⚪ | `[{name: X, value: Y}]` | 追加环境变量 |
| `replicaCount` | ⚪ | `2`（默认）| 副本数。stateless HTTP 已启用，多副本安全 |

## Mode A vs Mode B

- **Mode A**（`externalSecrets.enabled=false`，默认）：你手动管 K8s Secret。简单，适合起步。
- **Mode B**（`externalSecrets.enabled=true`）：Chart 渲染 ExternalSecret，ESO 从 Secrets Manager 同步。需要先装 ESO + 配 ClusterSecretStore。详见 [../SETUP.md](../SETUP.md) "ESO" 章节。

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
