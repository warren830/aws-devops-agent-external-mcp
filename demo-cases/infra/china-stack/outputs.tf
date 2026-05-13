###############################################################################
# Outputs — used by fault-injection scripts and case docs.
###############################################################################

output "partition" {
  description = "Resolved AWS partition (aws-cn)."
  value       = local.partition
}

output "region" {
  value = local.region
}

output "account_id" {
  value = local.account_id
}

output "vpc_id" {
  value = data.aws_vpc.default.id
}

output "subnet_ids" {
  value = data.aws_subnets.default.ids
}

output "ecr_repo_url" {
  value = aws_ecr_repository.etl_worker.repository_url
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.china_data.name
}

output "etl_worker_service_name" {
  value = aws_ecs_service.etl_worker.name
}

output "report_generator_service_name" {
  value = aws_ecs_service.report_generator.name
}

output "sqs_queue_url" {
  value = aws_sqs_queue.etl_jobs.url
}

output "sqs_queue_arn" {
  value = aws_sqs_queue.etl_jobs.arn
}

output "dynamodb_table_name" {
  value = aws_dynamodb_table.etl_state.name
}

output "lambda_etl_trigger_name" {
  value = aws_lambda_function.etl_trigger.function_name
}

output "rds_endpoint" {
  value = aws_db_instance.china_data.address
}

output "rds_identifier" {
  value = aws_db_instance.china_data.identifier
}

output "s3_input_bucket" {
  value = aws_s3_bucket.input.bucket
}

output "s3_output_bucket" {
  value = aws_s3_bucket.output.bucket
}

output "sns_alarms_topic_arn" {
  value = aws_sns_topic.alarms.arn
}

output "ecs_tasks_security_group_id" {
  value = aws_security_group.ecs_tasks.id
}
