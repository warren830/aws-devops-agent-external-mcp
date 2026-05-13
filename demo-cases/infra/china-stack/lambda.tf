###############################################################################
# Lambda etl-trigger — pushes 100 stub items into the etl-jobs SQS queue.
# Source code is in lambda/handler.py; we zip it inline via archive_file.
###############################################################################

data "archive_file" "etl_trigger" {
  type        = "zip"
  source_file = "${path.module}/lambda/handler.py"
  output_path = "${path.module}/build/etl-trigger.zip"
}

resource "aws_cloudwatch_log_group" "etl_trigger" {
  name              = "/aws/lambda/etl-trigger"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "etl_trigger" {
  function_name = "etl-trigger"
  description   = "Pushes stub ETL jobs into the etl-jobs SQS queue"

  filename         = data.archive_file.etl_trigger.output_path
  source_code_hash = data.archive_file.etl_trigger.output_base64sha256

  role    = aws_iam_role.lambda_etl_trigger.arn
  runtime = "python3.12"
  handler = "handler.lambda_handler"

  timeout     = 30
  memory_size = 256

  environment {
    variables = {
      ETL_QUEUE_URL = aws_sqs_queue.etl_jobs.url
      ITEMS_PER_RUN = "100"
      LOG_LEVEL     = "INFO"
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.lambda_basic_exec,
    aws_cloudwatch_log_group.etl_trigger,
  ]
}
