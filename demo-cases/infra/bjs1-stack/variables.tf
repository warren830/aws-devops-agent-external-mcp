variable "region" {
  description = "AWS region (Beijing partition)"
  type        = string
  default     = "cn-north-1"
}

variable "aws_profile" {
  description = "AWS named profile to use; users must `unset AWS_PROFILE AWS_REGION` first because the harness env var overrides this."
  type        = string
  default     = "ychchen-bjs1"
}

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
  default     = "bjs-web"
}

variable "kubernetes_version" {
  description = "EKS Kubernetes control-plane version. v1.31 is GA in cn-north-1 as of 2026."
  type        = string
  default     = "1.31"
}

variable "node_instance_type" {
  description = "EKS managed nodegroup instance type"
  type        = string
  default     = "t3.medium"
}

variable "node_desired_size" {
  description = "EKS managed nodegroup desired size"
  type        = number
  default     = 1
}

variable "db_name" {
  description = "RDS PostgreSQL database name"
  type        = string
  default     = "bjs_todo_db"
}

variable "db_username" {
  description = "RDS master username"
  type        = string
  default     = "todoadmin"
}

variable "db_engine_version" {
  description = "PostgreSQL engine version. 16.x line, db.t3.micro compatible."
  type        = string
  default     = "16.13"
}

variable "ecr_repository_name" {
  description = "Name of the ECR repository for the demo container image"
  type        = string
  default     = "bjs-todo-api"
}

variable "random_suffix" {
  description = "Optional override for the random suffix used by the S3 uploads bucket. Leave empty to auto-generate."
  type        = string
  default     = ""
}

# Random ID used to make the S3 bucket name globally unique within cn-north-1.
resource "random_id" "suffix" {
  byte_length = 3
}

# Random password for the RDS master user. Stored in Secrets Manager (see rds.tf).
resource "random_password" "db_password" {
  length           = 24
  special          = true
  override_special = "!#$%^&*()-_=+[]{}<>?"
}

locals {
  bucket_suffix = var.random_suffix != "" ? var.random_suffix : random_id.suffix.hex
}
