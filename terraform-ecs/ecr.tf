# -----------------------------------------------------------------------------
# ECR repositories — one per provider type (aws, aliyun).
# After terraform apply, push images with:
#   docker build -t <repo_url>:latest -f deploy/Dockerfile .
#   docker push <repo_url>:latest
# -----------------------------------------------------------------------------

resource "aws_ecr_repository" "mcp" {
  for_each = var.images

  name                 = "${var.name_prefix}-${each.key}"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

locals {
  ecr_urls = { for k, v in aws_ecr_repository.mcp : k => v.repository_url }
}
