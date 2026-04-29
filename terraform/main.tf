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

# --- VPC：只用公有子网，不要 NAT（省 EIP） ---
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = local.name
  cidr = "10.42.0.0/16"
  azs  = local.azs

  public_subnets = ["10.42.0.0/20", "10.42.16.0/20"]

  enable_nat_gateway            = false
  enable_dns_hostnames          = true
  map_public_ip_on_launch       = true

  public_subnet_tags = {
    "kubernetes.io/role/elb"          = "1"
    "kubernetes.io/role/internal-elb" = "1"
  }
}

# --- EKS：节点跑在公有子网 ---
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = local.name
  cluster_version = "1.31"

  vpc_id                         = module.vpc.vpc_id
  subnet_ids                     = module.vpc.public_subnets
  cluster_endpoint_public_access = true

  enable_cluster_creator_admin_permissions = true

  eks_managed_node_groups = {
    default = {
      instance_types = ["t3.medium"]
      min_size       = 1
      max_size       = 2
      desired_size   = 1
      subnet_ids     = module.vpc.public_subnets
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
output "lb_controller_role_arn" { value = module.lb_controller_irsa.iam_role_arn }
output "kubeconfig_cmd" {
  value = "aws eks update-kubeconfig --region us-east-1 --name ${module.eks.cluster_name}"
}
