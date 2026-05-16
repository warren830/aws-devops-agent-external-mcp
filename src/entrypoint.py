"""
AWS API MCP Server entrypoint with kubectl extension.

Imports the upstream FastMCP server instance and registers an additional
call_kubectl tool before calling main(). This keeps the aws-cn-2 MCP
endpoint at a single port with a single Agent Space connection.

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


@server.tool(
    name="call_kubectl",
    description="""Execute read-only kubectl commands against the configured EKS cluster.

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
""",
)
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


# ---------------------------------------------------------------------------
# Start the server
# ---------------------------------------------------------------------------
from awslabs.aws_api_mcp_server.server import main  # noqa: E402

if __name__ == "__main__":
    main()
