variable "region" {
  description = "AWS region for the ECS cluster and ALB"
  type        = string
  default     = "us-east-1"
}

variable "name_prefix" {
  description = "Prefix for all resource names"
  type        = string
  default     = "mcp"
}

variable "vpc_id" {
  description = "ID of existing VPC. Leave empty to create a new VPC."
  type        = string
  default     = ""
}

variable "public_subnet_ids" {
  description = "Public subnet IDs (required when using existing VPC)"
  type        = list(string)
  default     = []
}

variable "private_subnet_ids" {
  description = "Private subnet IDs (required when using existing VPC)"
  type        = list(string)
  default     = []
}

variable "certificate_arn" {
  description = "ACM certificate ARN for HTTPS listener"
  type        = string
}

variable "images" {
  description = "Image tags per provider type. ECR repos are auto-created."
  type = map(object({
    tag = optional(string, "latest")
  }))
  default = {
    aws    = {}
    aliyun = {}
  }
}

# ---------------------------------------------------------------------------
# Per-account configuration
# ---------------------------------------------------------------------------
variable "accounts" {
  description = <<-EOT
    Map of MCP accounts to deploy. Each key is a short identifier (e.g. "aws-cn").

    auth_mode:
      "ak_sk"           — traditional AK/SK stored in Secrets Manager (default)
      "roles_anywhere"  — X.509 cert → Roles Anywhere → Hub → AssumeRole to spoke

    For auth_mode = "ak_sk":     access_key + secret_key are required.
    For auth_mode = "roles_anywhere": spoke_role_arn is required, plus var.roles_anywhere global config.
  EOT

  type = map(object({
    provider       = optional(string, "aws")        # "aws" | "aliyun"
    host           = string                         # Hostname for ALB routing
    aws_region     = optional(string, "")           # AWS region (aws provider only)
    aliyun_env     = optional(string, "domestic")   # "domestic" | "international" (aliyun only)
    auth_mode      = optional(string, "ak_sk")      # "ak_sk" | "roles_anywhere"
    access_key     = optional(string, "")           # AK (required for ak_sk)
    secret_key     = optional(string, "")           # SK (required for ak_sk)
    spoke_role_arn = optional(string, "")           # Target role ARN (required for roles_anywhere)
    use_entrypoint = optional(bool, false)          # true → use entrypoint.py with call_kubectl
    eks_cluster    = optional(string, "")           # Required when use_entrypoint=true
    eks_region     = optional(string, "")           # Required when use_entrypoint=true
  }))
}

# ---------------------------------------------------------------------------
# Roles Anywhere global config (shared by all accounts with auth_mode = "roles_anywhere")
# ---------------------------------------------------------------------------
variable "roles_anywhere" {
  description = <<-EOT
    Global Roles Anywhere configuration. Required when any account uses auth_mode = "roles_anywhere".
    Certificate and key are stored in Secrets Manager (plain PEM text, not JSON).
  EOT

  type = object({
    cert_secret_arn  = string  # SM secret ARN holding client certificate PEM
    key_secret_arn   = string  # SM secret ARN holding client private key PEM
    trust_anchor_arn = string  # Roles Anywhere Trust Anchor ARN (in China region)
    profile_arn      = string  # Roles Anywhere Profile ARN (in China region)
    hub_role_arn     = string  # Hub Role ARN (in China region)
    region           = string  # China region where Roles Anywhere is configured
    external_id      = optional(string, "mcp-bridge")
  })

  default = null
}
