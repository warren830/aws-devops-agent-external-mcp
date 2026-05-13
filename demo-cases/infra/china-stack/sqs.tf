###############################################################################
# SQS queue that feeds the etl-worker.
# Standard queue (not FIFO). Used by Lambda etl-trigger as producer and
# ECS service etl-worker as consumer.
###############################################################################
resource "aws_sqs_queue" "etl_jobs_dlq" {
  name                      = "etl-jobs-dlq"
  message_retention_seconds = 1209600 # 14 days
}

resource "aws_sqs_queue" "etl_jobs" {
  name                       = "etl-jobs"
  visibility_timeout_seconds = 300
  message_retention_seconds  = 345600 # 4 days
  receive_wait_time_seconds  = 10     # long polling

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.etl_jobs_dlq.arn
    maxReceiveCount     = 5
  })
}
