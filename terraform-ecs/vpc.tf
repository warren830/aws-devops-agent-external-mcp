# -----------------------------------------------------------------------------
# VPC — created only when var.vpc_id is empty (customer doesn't have one).
# When var.vpc_id is set, all resources here are skipped via count = 0.
# -----------------------------------------------------------------------------

locals {
  create_vpc = var.vpc_id == ""
  vpc_id     = local.create_vpc ? aws_vpc.this[0].id : var.vpc_id
  vpc_cidr   = local.create_vpc ? aws_vpc.this[0].cidr_block : data.aws_vpc.existing[0].cidr_block

  public_subnet_ids = local.create_vpc ? [
    aws_subnet.public[0].id, aws_subnet.public[1].id
  ] : var.public_subnet_ids

  private_subnet_ids = local.create_vpc ? [
    aws_subnet.private[0].id, aws_subnet.private[1].id
  ] : var.private_subnet_ids
}

data "aws_vpc" "existing" {
  count = local.create_vpc ? 0 : 1
  id    = var.vpc_id
}

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "this" {
  count                = local.create_vpc ? 1 : 0
  cidr_block           = "10.42.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${var.name_prefix}-vpc" }
}

resource "aws_subnet" "public" {
  count             = local.create_vpc ? 2 : 0
  vpc_id            = aws_vpc.this[0].id
  cidr_block        = cidrsubnet("10.42.0.0/16", 4, count.index)
  availability_zone = data.aws_availability_zones.available.names[count.index]
  tags              = { Name = "${var.name_prefix}-public-${count.index}" }
}

resource "aws_subnet" "private" {
  count             = local.create_vpc ? 2 : 0
  vpc_id            = aws_vpc.this[0].id
  cidr_block        = cidrsubnet("10.42.0.0/16", 4, count.index + 8)
  availability_zone = data.aws_availability_zones.available.names[count.index]
  tags              = { Name = "${var.name_prefix}-private-${count.index}" }
}
