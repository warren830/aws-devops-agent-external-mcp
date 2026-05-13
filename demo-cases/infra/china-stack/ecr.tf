###############################################################################
# ECR repository for the etl-worker container image.
# (Same repo serves as default for the report-generator until we split images.)
###############################################################################
resource "aws_ecr_repository" "etl_worker" {
  name                 = "etl-worker"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_ecr_lifecycle_policy" "etl_worker" {
  repository = aws_ecr_repository.etl_worker.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep only the last 10 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}
