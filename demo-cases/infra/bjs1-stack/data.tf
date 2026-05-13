# Resolve partition (will be `aws-cn` in cn-north-1) and account context.
data "aws_partition" "current" {}

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

# Reuse the existing default VPC. The user has confirmed:
#   vpc-0bf919360d6e5b484  (172.31.0.0/16)
data "aws_vpc" "default" {
  default = true
}

# All subnets in the default VPC (default-VPC subnets are public by default).
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Per-subnet detail so we can extract availability zones (RDS subnet group needs >= 2 AZs).
data "aws_subnet" "default" {
  for_each = toset(data.aws_subnets.default.ids)
  id       = each.value
}

locals {
  # Distinct subnet-per-AZ (RDS subnet groups dislike duplicate-AZ subnets).
  default_subnet_ids_by_az = {
    for s in data.aws_subnet.default : s.availability_zone => s.id...
  }
  # Pick the first subnet in each AZ for RDS / EKS so we get one-per-AZ coverage.
  one_subnet_per_az = [
    for az, ids in local.default_subnet_ids_by_az : ids[0]
  ]
}
