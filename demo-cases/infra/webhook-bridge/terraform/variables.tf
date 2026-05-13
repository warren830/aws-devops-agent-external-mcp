variable "name_prefix" {
  description = "Prefix used for the Lambda function, IAM role, and log group. Example: 'devops-agent-bridge-bjs1'."
  type        = string
  default     = "devops-agent-bridge"
}

variable "aws_region" {
  description = "AWS region to deploy into. For China accounts, use cn-north-1 (bjs1) or cn-northwest-1 (china)."
  type        = string
}

variable "sns_topic_arns" {
  description = "List of SNS topic ARNs to subscribe the Lambda to. One per case category (e.g. one per alarm type)."
  type        = list(string)

  validation {
    condition     = length(var.sns_topic_arns) > 0
    error_message = "At least one SNS topic ARN must be supplied."
  }
}

variable "ssm_parameter_prefix" {
  description = <<-EOT
    Prefix under which the webhook URL and secret are stored in SSM Parameter Store.

    Two parameters are read at runtime:
      <prefix>/webhook-url     (String)
      <prefix>/webhook-secret  (SecureString)

    Default: '/devops-agent'.
  EOT
  type        = string
  default     = "/devops-agent"
}

variable "ssm_secret_kms_key_arn" {
  description = <<-EOT
    KMS key ARN that protects the SecureString webhook-secret parameter.

    Set to null to use the AWS-managed key 'alias/aws/ssm' - in that case the
    Lambda role will get a wildcard kms:Decrypt scoped via 'kms:ViaService'.

    For tighter control, store the secret under a customer-managed key and
    pass that ARN here.
  EOT
  type        = string
  default     = null
}

variable "lambda_memory_mb" {
  description = "Lambda memory size in MB."
  type        = number
  default     = 256
}

variable "lambda_timeout_seconds" {
  description = "Lambda timeout in seconds."
  type        = number
  default     = 30
}

variable "lambda_log_retention_days" {
  description = "CloudWatch Logs retention for the Lambda's log group."
  type        = number
  default     = 14
}

variable "tags" {
  description = "Common tags applied to all resources."
  type        = map(string)
  default = {
    Project = "aws-devops-agent-external-mcp"
    Stack   = "webhook-bridge"
  }
}
