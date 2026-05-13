provider "aws" {
  profile = var.aws_profile
  region  = var.aws_region

  default_tags {
    tags = {
      Project     = "aws-devops-agent-demo"
      Stack       = "china-data"
      Environment = "demo"
      ManagedBy   = "terraform"
      Owner       = "ychchen"
    }
  }
}
