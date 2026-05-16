# ----------------------------------------------------------------------------
# MCP pod read-only access to bjs-web EKS cluster
#
# Two resources:
#   1. mcp-readonly ClusterRole — get/list/watch only, no exec/write
#   2. aws-auth ConfigMap patch — maps the MCP IAM identity into that role
#
# The IAM identity is the same AK/SK user (demo) or IRSA role (production)
# used by the aws-cn MCP pod. See deploy/README.md "凭证方案选择".
#
# Variable mcp_iam_user_arn must be set to the ARN of the IAM identity
# that the MCP pod authenticates as. In demo this is an IAM user; in
# production replace with the IRSA role ARN.
# ----------------------------------------------------------------------------

variable "mcp_iam_user_arn" {
  description = "ARN of the IAM identity used by the MCP pod (IAM user for demo, IRSA role for production)"
  type        = string
  default     = ""
}

# ---- ClusterRole: read-only access for MCP pod ------------------------------

resource "kubernetes_cluster_role_v1" "mcp_readonly" {
  metadata {
    name = "mcp-readonly"
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  rule {
    api_groups = [""]
    resources  = ["pods", "pods/log", "events", "services", "endpoints",
                   "namespaces", "nodes", "configmaps"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["apps"]
    resources  = ["deployments", "replicasets", "daemonsets", "statefulsets"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["batch"]
    resources  = ["jobs", "cronjobs"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["networking.k8s.io"]
    resources  = ["ingresses"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "mcp_readonly" {
  metadata {
    name = "mcp-readonly"
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.mcp_readonly.metadata[0].name
  }

  subject {
    kind      = "Group"
    name      = "mcp-readonly"
    api_group = "rbac.authorization.k8s.io"
  }
}

# ---- aws-auth ConfigMap patch -----------------------------------------------
# Uses kubernetes_config_map_v1_data (not kubernetes_config_map) so that
# EKS-managed entries (nodegroup mapRoles) are preserved and only the
# mapUsers block is added/updated by Terraform.

resource "kubernetes_config_map_v1_data" "aws_auth" {
  count = var.mcp_iam_user_arn != "" ? 1 : 0

  metadata {
    name      = "aws-auth"
    namespace = "kube-system"
  }

  # Merge into existing ConfigMap — EKS nodegroup mapRoles entries are untouched.
  force = false

  data = {
    mapUsers = yamlencode([
      {
        userarn  = var.mcp_iam_user_arn
        username = "mcp-agent"
        groups   = ["mcp-readonly"]
      }
    ])
  }
}
