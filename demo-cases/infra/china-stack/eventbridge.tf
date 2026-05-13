###############################################################################
# EventBridge Scheduler: daily 00:00 UTC (= 08:00 Beijing) trigger of
# the etl-trigger Lambda.
#
# Using aws_scheduler_schedule (EventBridge Scheduler) instead of the
# legacy CloudWatch Events rule — Scheduler is the recommended path and
# supports cn partition.
###############################################################################

resource "aws_scheduler_schedule" "etl_daily" {
  name        = "etl-trigger-daily"
  description = "Daily 00:00 UTC trigger for the etl-trigger Lambda"

  flexible_time_window {
    mode = "OFF"
  }

  # cron(min hour day-of-month month day-of-week year) — daily at 00:00 UTC
  schedule_expression          = "cron(0 0 * * ? *)"
  schedule_expression_timezone = "UTC"

  target {
    arn      = aws_lambda_function.etl_trigger.arn
    role_arn = aws_iam_role.scheduler.arn

    input = jsonencode({
      source = "eventbridge-scheduler",
      reason = "daily-etl-trigger"
    })

    retry_policy {
      maximum_event_age_in_seconds = 3600
      maximum_retry_attempts       = 2
    }
  }
}
