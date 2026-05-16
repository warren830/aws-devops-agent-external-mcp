provider "aws" {
  region  = var.region
  profile = var.aws_profile

  default_tags {
    tags = {
      Project     = "devops-agent-demo"
      Environment = "demo"
    }
  }
}

# kubernetes provider — used only for aws-auth ConfigMap management.
# Authenticates via the same EKS cluster created in eks.tf.
provider "kubernetes" {
  host                   = aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(aws_eks_cluster.this.certificate_authority[0].data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = [
      "eks", "get-token",
      "--cluster-name", aws_eks_cluster.this.name,
      "--region", var.region,
      "--profile", var.aws_profile,
    ]
  }
}
