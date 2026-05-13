variable "aws_profile" {
  description = "AWS named profile to use (must be set up in ~/.aws/config)."
  type        = string
  default     = "ychchen-china"
}

variable "aws_region" {
  description = "AWS region for the China data stack."
  type        = string
  default     = "cn-northwest-1"
}

variable "vpc_id" {
  description = "Existing default VPC to reuse (172.31.0.0/16)."
  type        = string
  default     = "vpc-046d31d4731d50516"
}

variable "name_prefix" {
  description = "Common name prefix for resources in this stack."
  type        = string
  default     = "china-data"
}

variable "etl_image" {
  description = "Container image for the etl-worker task. Defaults to the ECR repo at :latest."
  type        = string
  default     = ""
}

variable "report_image" {
  description = "Container image for the report-generator task. Defaults to the ECR repo at :latest."
  type        = string
  default     = ""
}

variable "rds_db_name" {
  description = "Initial database name for the multi-AZ MySQL instance."
  type        = string
  default     = "chinadata"
}

variable "rds_master_username" {
  description = "Master username for the multi-AZ MySQL instance."
  type        = string
  default     = "chinadata_admin"
}

variable "rds_master_password" {
  description = "Master password for the multi-AZ MySQL instance. Override via TF_VAR_rds_master_password."
  type        = string
  sensitive   = true
  default     = "ChangeMe-Demo-2026!"
}

variable "alarm_email" {
  description = "Optional email subscription for the SNS alarm topic. Leave empty to skip."
  type        = string
  default     = ""
}

variable "etl_task_cpu" {
  description = "ETL Fargate task CPU (in CPU units). 256 = 0.25 vCPU. DELIBERATELY small to drive C3."
  type        = number
  default     = 256
}

variable "etl_task_memory" {
  description = "ETL Fargate task memory (MB). DELIBERATELY too small to drive OOM in C3."
  type        = number
  default     = 512
}

variable "report_task_cpu" {
  description = "Report-generator Fargate task CPU."
  type        = number
  default     = 512
}

variable "report_task_memory" {
  description = "Report-generator Fargate task memory."
  type        = number
  default     = 1024
}

variable "log_retention_days" {
  description = "CloudWatch log retention for ECS / Lambda log groups."
  type        = number
  default     = 14
}
