"""
AWS API MCP Server entrypoint with kubectl and inventory extensions.

Imports the upstream FastMCP server instance and registers additional
call_kubectl and cn_list_inventory tools before calling main(). This keeps the
aws-cn-2 MCP endpoint at a single port with a single Agent Space connection.

kubectl authentication: on startup we run `aws eks update-kubeconfig`
using the ambient AWS credentials (same AK/SK used by call_aws). The
kubeconfig is written to /tmp/kubeconfig and KUBECONFIG is set so that
kubectl picks it up automatically.

Read-only enforcement: only get/describe/logs/top/explain verbs are
permitted. Any other verb is rejected before execution.
"""

import os
import re
import subprocess
import logging

# Without an explicit level the root logger defaults to WARNING, so the
# registration messages below never reach CloudWatch -- which makes it
# impossible to confirm from logs which tools a container actually registered.
logging.basicConfig(
    level=os.environ.get("LOG_LEVEL", "INFO").upper(),
    format="[%(levelname)s] %(name)s: %(message)s",
)
logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Bootstrap kubeconfig on startup (best-effort — kubectl tools will return
# a clear error if the cluster is unreachable or creds are missing).
# ---------------------------------------------------------------------------
_KUBECONFIG_PATH = "/tmp/kubeconfig"
_EKS_CLUSTER_NAME = os.environ.get("EKS_CLUSTER_NAME", "")
_EKS_REGION = os.environ.get("EKS_REGION", os.environ.get("AWS_DEFAULT_REGION", ""))

os.environ.setdefault("KUBECONFIG", _KUBECONFIG_PATH)

if _EKS_CLUSTER_NAME and _EKS_REGION:
    try:
        subprocess.run(
            [
                "aws", "eks", "update-kubeconfig",
                "--name", _EKS_CLUSTER_NAME,
                "--region", _EKS_REGION,
                "--kubeconfig", _KUBECONFIG_PATH,
            ],
            check=True,
            capture_output=True,
        )
        logger.info("kubeconfig generated for cluster %s", _EKS_CLUSTER_NAME)
    except subprocess.CalledProcessError as e:
        logger.warning("Failed to generate kubeconfig: %s", e.stderr.decode())
else:
    logger.info("EKS_CLUSTER_NAME or EKS_REGION not set — skipping kubeconfig bootstrap")

# ---------------------------------------------------------------------------
# Register call_kubectl on the upstream server instance
# ---------------------------------------------------------------------------
from typing import Annotated
from pydantic import Field
from awslabs.aws_api_mcp_server.server import server  # noqa: E402

_ALLOWED_VERBS = frozenset([
    "get", "describe", "logs", "top", "explain",
    "version", "cluster-info", "api-resources", "api-versions",
])

_COMMAND_RE = re.compile(r"^kubectl\s+(\S+)")


_KUBECTL_DESCRIPTION = """Execute read-only kubectl commands against the configured EKS cluster.

Only the following verbs are permitted: get, describe, logs, top, explain,
version, cluster-info, api-resources, api-versions.

Write operations (apply, delete, patch, exec, port-forward, etc.) are
rejected. For remediation commands, output the command as a draft for
human approval — do not call this tool with write verbs.

Examples:
  call_kubectl("kubectl get pods -n bjs-web -o wide")
  call_kubectl("kubectl describe pod <name> -n bjs-web")
  call_kubectl("kubectl logs <pod> -n bjs-web --since=1h")
  call_kubectl("kubectl get events -n bjs-web --sort-by=.lastTimestamp")
  call_kubectl("kubectl get deployments -n bjs-web")
"""


async def call_kubectl(
    command: Annotated[str, Field(description="A complete kubectl command starting with 'kubectl'")],
) -> str:
    if not command.strip().startswith("kubectl "):
        return "Error: command must start with 'kubectl '"

    m = _COMMAND_RE.match(command.strip())
    if not m:
        return "Error: could not parse kubectl verb"

    verb = m.group(1).lower()
    if verb not in _ALLOWED_VERBS:
        return (
            f"Error: verb '{verb}' is not permitted. "
            f"Allowed verbs: {', '.join(sorted(_ALLOWED_VERBS))}. "
            "For write operations, output the command as a draft for human approval."
        )

    try:
        result = subprocess.run(
            command.split(),
            capture_output=True,
            text=True,
            timeout=30,
            env={**os.environ, "KUBECONFIG": _KUBECONFIG_PATH},
        )
        output = result.stdout or result.stderr
        return output if output else "(no output)"
    except subprocess.TimeoutExpired:
        return "Error: kubectl command timed out after 30s"
    except Exception as e:
        return f"Error: {e}"


# Register call_kubectl only for accounts that actually have an EKS cluster.
# Advertising a tool that can only ever return "cluster unreachable" wastes the
# agent's tool budget and invites it down a dead end.
if _EKS_CLUSTER_NAME and _EKS_REGION:
    server.tool(name="call_kubectl", description=_KUBECTL_DESCRIPTION)(call_kubectl)
    logger.info("call_kubectl registered for cluster %s", _EKS_CLUSTER_NAME)
else:
    logger.info("EKS not configured — call_kubectl not registered")


# ---------------------------------------------------------------------------
# Register cn_list_inventory on the upstream server instance
# ---------------------------------------------------------------------------
import json  # noqa: E402

import cn_inventory  # noqa: E402


@server.tool(
    name="cn_list_inventory",
    description="""Batch inventory of this AWS China (aws-cn) account's resources in ONE call.

Use this FIRST when you need to know what exists in this China account — before
running individual describe/list calls with call_aws. It merges AWS Resource
Explorer and the Resource Groups Tagging API, because measurement shows neither
API alone is complete: on a real cn account Resource Explorer saw 128 resources,
the Tagging API saw 176, and only 27 overlapped. Resource Explorer finds
untagged resources (CloudWatch log groups, KMS keys, ECR repos); the Tagging API
finds tagged resources Resource Explorer misses (SageMaker, S3, ECS) and returns
the aws:cloudformation:stack-name tags that give deployment lineage.

When to use:
  - "What resources exist in this China account?" / inventory / stocktake
  - Building or refreshing a topology view of the China environment
  - "Which CloudFormation stacks are deployed here?" (see cloudformation_stacks)
  - "Where are the EKS/RDS/ECS resources?" (filter by service)
  - Cross-region questions: an AGGREGATOR index covers all regions in one call

When NOT to use:
  - Full configuration of one known resource → use call_aws describe-*
  - Pod logs or Kubernetes state → use call_kubectl
  - Relationship edges between resources (which SG is on which ENI) → not
    available here; only AWS Config exposes those, and it must be enabled first

Modes (start with summary, it is bounded regardless of estate size):
  "summary" (default) — counts by service / resource type / region, plus
                        CloudFormation stack names and tag keys. ~1k tokens.
  "list"              — one line per resource. ALWAYS pass a filter, or this
                        can be very large (~300 bytes per resource).
  "detail"            — full records including all tags.

ALWAYS read the "coverage" and "completeness" fields before answering the user.
The payload reports its own blind spots — a LOCAL (non-aggregator) index covers
only one region, and a still-building index returns partial data. Report the
scope you actually saw; do not present a partial result as the full estate.

Examples:
  cn_list_inventory()
  cn_list_inventory(mode="summary", region="cn-north-1")
  cn_list_inventory(mode="list", service="eks")
  cn_list_inventory(mode="list", resource_type="ec2:vpc")
  cn_list_inventory(mode="list", tag_key="aws:cloudformation:stack-name", limit=100)
""",
)
# Declared sync, not async. The body is blocking (up to four sequential paginated
# boto3 calls), and FastMCP awaits a coroutine directly instead of handing it to a
# threadpool -- so as an `async def` one inventory sweep stalls the whole server,
# including the ALB health check on /mcp. With a 30s interval and 3 unhealthy
# checks, a slow sweep gets the task deregistered mid-call. A plain `def` is
# dispatched to a worker thread instead.
def cn_list_inventory(  # sync on purpose -- see note below
    mode: Annotated[str, Field(default="summary", description="summary | list | detail")] = "summary",
    service: Annotated[str, Field(default="", description="Filter by AWS service, e.g. 'ec2', 'eks', 's3'")] = "",
    resource_type: Annotated[str, Field(default="", description="Filter by resource type substring, e.g. 'ec2:vpc'")] = "",
    region: Annotated[str, Field(default="", description="Filter results to one region, e.g. 'cn-north-1'")] = "",
    tag_key: Annotated[str, Field(default="", description="Only resources carrying this tag key")] = "",
    limit: Annotated[int, Field(default=200, description="Max resources for list/detail mode")] = 200,
) -> str:
    try:
        result = cn_inventory.collect_inventory(
            mode=mode,
            service=service or None,
            resource_type=resource_type or None,
            region_filter=region or None,
            tag_key=tag_key or None,
            limit=limit,
            query_region=os.environ.get("AWS_DEFAULT_REGION") or None,
        )
        return json.dumps(result, ensure_ascii=False, indent=2, default=str)
    except Exception as e:  # surface the failure to the agent instead of crashing the tool
        logger.exception("cn_list_inventory failed")
        return json.dumps({"error": f"{type(e).__name__}: {e}"}, ensure_ascii=False)


# ---------------------------------------------------------------------------
# Start the server
# ---------------------------------------------------------------------------
from awslabs.aws_api_mcp_server.server import main  # noqa: E402

if __name__ == "__main__":
    main()
