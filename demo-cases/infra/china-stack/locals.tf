locals {
  partition  = data.aws_partition.current.partition # "aws-cn" in cn-northwest-1
  region     = data.aws_region.current.name
  account_id = data.aws_caller_identity.current.account_id

  # Default to the in-stack ECR repo @ :latest if caller didn't override.
  etl_image_resolved    = var.etl_image == "" ? "${aws_ecr_repository.etl_worker.repository_url}:latest" : var.etl_image
  report_image_resolved = var.report_image == "" ? "${aws_ecr_repository.etl_worker.repository_url}:latest" : var.report_image

  common_tags = {
    Project = "aws-devops-agent-demo"
    Stack   = "china-data"
  }
}
