output "cluster_name" {
  description = "EKS cluster name"
  value       = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  description = "EKS cluster API endpoint"
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_oidc_issuer" {
  description = "EKS cluster OIDC issuer URL (used for IRSA)"
  value       = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

output "alb_controller_role_arn" {
  description = "IAM role ARN for AWS Load Balancer Controller (use for IRSA in Helm chart)"
  value       = aws_iam_role.alb_controller.arn
}

output "ecr_repository_url" {
  description = "ECR repository URL for bjs-todo-api"
  value       = aws_ecr_repository.todo_api.repository_url
}

output "rds_endpoint" {
  description = "RDS PostgreSQL endpoint (host:port)"
  value       = "${aws_db_instance.todo.address}:${aws_db_instance.todo.port}"
}

output "rds_secret_arn" {
  description = "Secrets Manager ARN holding RDS master credentials"
  value       = aws_secretsmanager_secret.db.arn
}

output "sns_alarms_topic_arn" {
  description = "SNS topic ARN that all bjs-web alarms publish to"
  value       = aws_sns_topic.alarms.arn
}

output "s3_uploads_bucket" {
  description = "S3 uploads bucket name"
  value       = aws_s3_bucket.uploads.bucket
}

output "cross_partition_test_role_arn" {
  description = "ARN of the deliberately broken cross-partition role (L7 fault driver for C5)"
  value       = aws_iam_role.cross_partition_test.arn
}

output "kubectl_config_command" {
  description = "Convenience command to update kubeconfig"
  value       = "aws --profile ${var.aws_profile} --region ${var.region} eks update-kubeconfig --name ${aws_eks_cluster.this.name} --alias bjs1"
}
