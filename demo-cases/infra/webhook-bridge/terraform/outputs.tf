output "lambda_function_name" {
  description = "Name of the bridge Lambda."
  value       = aws_lambda_function.bridge.function_name
}

output "lambda_function_arn" {
  description = "ARN of the bridge Lambda."
  value       = aws_lambda_function.bridge.arn
}

output "lambda_role_arn" {
  description = "IAM role ARN used by the Lambda."
  value       = aws_iam_role.lambda.arn
}

output "log_group_name" {
  description = "CloudWatch Log Group name for the Lambda."
  value       = aws_cloudwatch_log_group.lambda.name
}

output "subscribed_topic_arns" {
  description = "SNS topic ARNs the Lambda is subscribed to."
  value       = [for s in aws_sns_topic_subscription.bridge : s.topic_arn]
}

output "ssm_parameter_url_name" {
  description = "Expected SSM parameter name for the webhook URL."
  value       = local.ssm_url_param_name
}

output "ssm_parameter_secret_name" {
  description = "Expected SSM parameter name for the webhook secret."
  value       = local.ssm_secret_param_name
}
