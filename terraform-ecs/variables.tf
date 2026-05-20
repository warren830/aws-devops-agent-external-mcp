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
    Map of MCP accounts to deploy. Each key is a short identifier (e.g. "aws-global").
    Adding an account = adding one entry here. Terraform creates Secrets Manager
    secrets automatically from the provided access_key / secret_key.

    provider: "aws" or "aliyun" — determines which image and env vars to use.
  EOT

  type = map(object({
    provider       = optional(string, "aws") # "aws" | "aliyun"
    host           = string                  # Hostname for ALB routing
    aws_region     = optional(string, "")    # AWS region (aws provider only)
    aliyun_env     = optional(string, "domestic") # "domestic" | "international" (aliyun only)
    access_key     = string                  # AK for the target account
    secret_key     = string                  # SK for the target account
    use_entrypoint = optional(bool, false)   # true → use entrypoint.py with call_kubectl
    eks_cluster    = optional(string, "")    # Required when use_entrypoint=true
    eks_region     = optional(string, "")    # Required when use_entrypoint=true
  }))
}
