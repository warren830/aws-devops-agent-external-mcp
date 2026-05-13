data "aws_partition" "current" {}

data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

# Reuse the existing default VPC (172.31.0.0/16)
data "aws_vpc" "default" {
  id = var.vpc_id
}

# Default subnets in the VPC — used for ECS tasks, RDS subnet group
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [var.vpc_id]
  }
}
