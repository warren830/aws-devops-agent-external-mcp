terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" { region = "us-east-1" }

locals {
  name = "mcp-test"
  azs  = ["us-east-1a", "us-east-1b"]
}

# -----------------------------------------------------------------------------
# VPC
#
# Layout:
#   Public subnets  (10.42.0.0/20, 10.42.16.0/20)
#     └─ NAT Gateway lives here, internet-facing ALBs would live here (none today).
#   Private subnets (10.42.128.0/20, 10.42.144.0/20)
#     └─ EKS worker nodes, internal ALB, DevOps Agent Private Connection ENIs.
#
# NAT Gateway is REQUIRED for private-subnet nodes to pull the GCP MCP image
# from us-docker.pkg.dev (Google's registry can't be accessed via VPC endpoint).
# AWS ECR images can be reached via VPC endpoints if you want to drop NAT;
# see the "Level 3" section in README for that path.
#
# Cost note: single_nat_gateway = true (one NAT shared across both AZs) saves
# ~$32/month vs per-AZ NAT but is a SPOF. For real production, flip it to false.
# -----------------------------------------------------------------------------
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = local.name
  cidr = "10.42.0.0/16"
  azs  = local.azs

  public_subnets  = ["10.42.0.0/20",   "10.42.16.0/20"]
  private_subnets = ["10.42.128.0/20", "10.42.144.0/20"]

  enable_nat_gateway   = true
  single_nat_gateway   = true       # set to false for per-AZ NAT (HA, +$32/mo)
  enable_dns_hostnames = true

  # Nodes in private subnets no longer get public IPs.
  map_public_ip_on_launch = false

  # Subnet tagging for AWS Load Balancer Controller auto-discovery:
  # internet-facing ALBs go to public subnets; internal ALBs go to private.
  # Our Ingress uses scheme=internal, so it lands in the private subnets.
  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }
}

# -----------------------------------------------------------------------------
# EKS
# -----------------------------------------------------------------------------
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = local.name
  cluster_version = "1.31"

  vpc_id = module.vpc.vpc_id
  # Control-plane ENIs can live in both public + private for reachability;
  # worker nodes are pinned to private via the node group's subnet_ids below.
  subnet_ids                     = concat(module.vpc.private_subnets, module.vpc.public_subnets)
  cluster_endpoint_public_access = true   # kubectl from dev laptops; data path is unaffected

  enable_cluster_creator_admin_permissions = true

  eks_managed_node_groups = {
    default = {
      instance_types = ["t3.medium"]
      min_size       = 1
      max_size       = 2
      desired_size   = 1
      subnet_ids     = module.vpc.private_subnets
    }
  }
}

module "lb_controller_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name                              = "${local.name}-lb-controller"
  attach_load_balancer_controller_policy = true
  oidc_providers = {
    ex = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
}

output "cluster_name"           { value = module.eks.cluster_name }
output "region"                 { value = "us-east-1" }
output "vpc_id"                 { value = module.vpc.vpc_id }
output "public_subnets"         { value = module.vpc.public_subnets }
output "private_subnets"        { value = module.vpc.private_subnets }
output "lb_controller_role_arn" { value = module.lb_controller_irsa.iam_role_arn }
output "kubeconfig_cmd" {
  value = "aws eks update-kubeconfig --region us-east-1 --name ${module.eks.cluster_name}"
}
