---
name: china-region-multi-account-routing
description: Tool selection and account routing for the AWS China (aws-cn) MCP
  servers in this Agent Space. Use this skill whenever the request mentions
  "中国区", "China", "cn-north-1", "cn-northwest-1", "Beijing", "北京",
  "Ningxia", "宁夏", account 284567523170 or 107422471498, or asks to
  inventory / list / count / map / audit resources that live in the China
  partition. It says which tool to reach for first (cn_list_inventory before
  call_aws), which MCP server holds which account, and — critically — how to
  avoid answering a China-partition question with global-partition credentials.
  Also documents that MCP tool names must be fully qualified as
  <server>_<tool> (e.g. ecs-cn-mcp-1_cn_list_inventory).
---

# AWS China Region: Tool Selection and Account Routing

Two MCP servers cover AWS China. They are **not** interchangeable: each holds
credentials for one `aws-cn` account (via IAM Roles Anywhere — no long-lived
keys), and **their tool sets differ**.

| MCP server | Account | Regions it can see | Extra tool |
|---|---|---|---|
| `ecs-cn-mcp-1` | `284567523170` | **both** `cn-northwest-1` (Ningxia) and `cn-north-1` (Beijing) | — |
| `ecs-cn-mcp-2` | `107422471498` | `cn-north-1` (Beijing) | `call_kubectl` (EKS cluster `bjs-web`) |

Note `ecs-cn-mcp-1` spans **both** China regions through a cross-region
Resource Explorer aggregator index. Account and region are separate axes here —
do not assume one account means one region.

---

## Step 0 — Tool names must be fully qualified (read this first)

MCP tools are allowlisted under `<server name>_<tool name>`, **not** the bare
tool name. Calling the bare name fails with:

```
cn_list_inventory is not an allowlisted user tool and cannot be invoked.
```

That error is a naming mistake, **not** a permissions problem. Do not conclude
the tool is unavailable, and do not fall back to `gather_context` or `use_aws`.

| Server | Fully qualified tool names |
|---|---|
| `ecs-cn-mcp-1` | `ecs-cn-mcp-1_cn_list_inventory`, `ecs-cn-mcp-1_call_aws`, `ecs-cn-mcp-1_suggest_aws_commands` |
| `ecs-cn-mcp-2` | `ecs-cn-mcp-2_cn_list_inventory`, `ecs-cn-mcp-2_call_aws`, `ecs-cn-mcp-2_call_kubectl`, `ecs-cn-mcp-2_suggest_aws_commands` |

If a name is ever rejected, call `search_user_tools` with the bare name to get
the exact registered name, then retry with what it returns.

---

## Step 1 — Pick the right tool

This is where China-region questions most often go wrong. Choose by intent
(names below are shown bare for brevity — always prefix with the server name):

| The user is asking | Use | Notes |
|---|---|---|
| What resources exist / inventory / stocktake / count / "有哪些" | **`cn_list_inventory`** | Start with default `mode="summary"` |
| Topology, what is deployed, how the environment is laid out | **`cn_list_inventory`** | Summary gives service × type × region counts |
| Which CloudFormation stacks are deployed | **`cn_list_inventory`** | Read `summary.cloudformation_stacks` |
| Where are the EKS / RDS / ECS / S3 resources | **`cn_list_inventory`** | `mode="list"` + `service="eks"` etc. |
| Full configuration of one **known** resource | `call_aws` | Only after you know the resource exists |
| Pod state, container logs, Kubernetes events | `call_kubectl` | **`ecs-cn-mcp-2` only** |
| Which CLI command would do X | `suggest_aws_commands` | |

### Using `cn_list_inventory`

It merges AWS Resource Explorer with the Resource Groups Tagging API, because
neither is complete on its own — measured on a real account, Resource Explorer
saw 128 resources, the Tagging API saw 176, and only 27 overlapped. Never
assume a single AWS inventory API returns everything in this partition.

Escalate through the modes; do not jump straight to `detail`:

1. `ecs-cn-mcp-1_cn_list_inventory()` — summary. Bounded payload (~1k tokens) no matter how
   large the estate. Gives counts by service, resource type and region, plus
   CloudFormation stack names and tag keys.
2. `ecs-cn-mcp-1_cn_list_inventory(mode="list", service="ec2")` — enumerate a subset.
   **Always pass a filter** (`service`, `resource_type`, `region`, `tag_key`);
   an unfiltered list of a few thousand resources will exhaust the context.
3. `ecs-cn-mcp-1_cn_list_inventory(mode="detail", ...)` — full records with every tag.

**Always read `coverage` and `completeness` before answering.** The payload
reports its own blind spots: a `LOCAL` (non-aggregator) index covers only one
region, a still-building index returns partial data, and tags for other regions
may be missing. Tell the user what scope you actually saw. Never present a
partial result as the complete estate.

---

## Step 2 — Pick the right account

Apply in order; first match wins.

1. **Account named explicitly** ("aws-cn-2", "宁夏那个账号", "284567523170",
   "the Beijing account") → that server only.
2. **Region named, no account**:
   - `cn-northwest-1` / 宁夏 / Ningxia → `ecs-cn-mcp-1`
   - `cn-north-1` / 北京 / Beijing → **both** can hold Beijing resources.
     `ecs-cn-mcp-1` sees its own account's Beijing resources;
     `ecs-cn-mcp-2` is a different account that lives in Beijing. Ask which,
     or query both and label the results.
3. **Neither named** ("中国区的资源", "China AWS"): ambiguous. Either query
   both and merge with per-account labels (preferred), or ask one
   disambiguation question. Do not silently pick one.
4. **Comparison requests** ("对比两个账号") → always query both, side by side.

---

## Never do these

- **Never answer a China-partition question using `use_aws` with a
  global-partition account.** This is the single most common failure mode: the
  agent reaches for the built-in `use_aws` tool with account `034362076319`
  and regions like `us-east-1` / `us-west-2` / `eu-west-1`, runs dozens of
  `describe_*` calls, and reports results that have nothing to do with China.
  `aws-cn` is a **separate partition**. Global credentials return
  `AuthFailure` there, and global regions contain none of these resources.
  China data is reachable **only** through the two MCP servers above.
- **Never** `sts:AssumeRole` from one China account into the other. There is no
  trust relationship between `284567523170` and `107422471498`.
- **Never** assume the two accounts share IAM principals, VPCs, security
  groups or resource names. Any name collision is coincidental.
- **Never** silently fall back to the other account when one errors. If the
  user asked about account X and X is unreachable, report that failure.
- **Never** call `call_kubectl` against `ecs-cn-mcp-1` — that server has no
  EKS cluster and does not register the tool.
- **Never** treat `is not an allowlisted user tool` as "no permission". It means
  the tool name was not fully qualified. Prefix it with the server name (see
  Step 0) and retry — do not fall back to `gather_context` or `use_aws`.
- **Never** enumerate resource-by-resource with `call_aws` when the question is
  "what exists". That is what `cn_list_inventory` is for, and doing it the slow
  way costs dozens of round trips and still misses untagged resources.

---

## Attributing cross-account results

Never merge results from the two accounts without attribution. Every ARN,
instance ID or resource name must carry the account it came from — users have
independent access to each account, so an unattributed ARN is ambiguous.

**Side-by-side** (for narrow comparisons):

| Resource | 284567523170 (Ningxia+Beijing) | 107422471498 (Beijing) |
|---|---|---|
| VPC count | 3 | 1 |

**Grouped sections** (for lists):

```
### 284567523170 — cn-northwest-1
- vpc-046d31d4731d50516

### 107422471498 — cn-north-1
- vpc-0bf919360d6e5b484
```

---

## Examples

**Input**: "中国区账号 284567523170 里有哪些资源？按服务汇总"
**Action**: `ecs-cn-mcp-1_cn_list_inventory()`. Report `summary.by_service`
and `summary.by_region`. State the coverage from the `coverage` field.
**Do not** use `use_aws`.

**Input**: "中国区部署了哪些 CloudFormation 栈"
**Action**: `ecs-cn-mcp-1_cn_list_inventory()` and
`ecs-cn-mcp-2_cn_list_inventory()`, read
`summary.cloudformation_stacks`, label each stack with its account.

**Input**: "北京的 EKS 集群里 pod 状态怎么样"
**Action**: `ecs-cn-mcp-2_call_kubectl("kubectl get pods -A")`.

**Input**: "宁夏账号有几个 RDS 实例，配置是什么"
**Action**: First `ecs-cn-mcp-1_cn_list_inventory(mode="list", service="rds")`
to find them, then `ecs-cn-mcp-1_call_aws` per instance for full config.

**Input**: "两个中国区账号 VPC CIDR 有没有冲突"
**Action**: `ecs-cn-mcp-1_cn_list_inventory(mode="list", resource_type="ec2:vpc")`
and the `ecs-cn-mcp-2_` equivalent, then `call_aws describe-vpcs` for CIDRs,
compare, label by account.
