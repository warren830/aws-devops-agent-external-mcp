###############################################################################
# CloudWatch alarms + SNS topic.
# Container Insights is enabled on the cluster itself (ecs.tf).
###############################################################################

# ----- SNS topic for all china-data alarms -----
resource "aws_sns_topic" "alarms" {
  name = "china-data-alarms"
}

resource "aws_sns_topic_subscription" "alarm_email" {
  count     = var.alarm_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

# ----- ECS task failure rate alarm — drives C3 -----
# Watches the rate of stopped tasks for the etl-worker service.
# (We use ECS/ContainerInsights TaskCount-stopped equivalent: the
# RunningTaskCount drop from desired is the cleanest signal here.)
resource "aws_cloudwatch_metric_alarm" "ecs_etl_task_failures" {
  alarm_name          = "ecs-etl-task-failures"
  alarm_description   = "etl-worker running task count dropped below desired (C3 driver)"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  threshold           = 1
  treat_missing_data  = "breaching"

  metric_name = "RunningTaskCount"
  namespace   = "ECS/ContainerInsights"
  period      = 60
  statistic   = "Average"

  dimensions = {
    ClusterName = aws_ecs_cluster.china_data.name
    ServiceName = aws_ecs_service.etl_worker.name
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]
}

# ----- DynamoDB throttle alarm — drives C3 -----
resource "aws_cloudwatch_metric_alarm" "dynamodb_etl_state_throttle" {
  alarm_name          = "dynamodb-etl-state-throttle"
  alarm_description   = "etl-state DynamoDB write throttling (C3 driver)"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = 0
  treat_missing_data  = "notBreaching"

  metric_name = "ThrottledRequests"
  namespace   = "AWS/DynamoDB"
  period      = 60
  statistic   = "Sum"

  dimensions = {
    TableName = aws_dynamodb_table.etl_state.name
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]
}

# ----- Cost anomaly alarm placeholder — drives C10 -----
# Uses a metric math expression on EstimatedCharges (Billing namespace lives
# in us-east-1 globally for aws partition; in aws-cn there's no Billing
# metric exposed the same way, so this is a structural placeholder. The
# real C10 driver is Cost Explorer + the cross-account-cost-attribution
# skill — see case C10 spec).
resource "aws_cloudwatch_metric_alarm" "china_cost_anomaly" {
  alarm_name          = "china-cost-anomaly"
  alarm_description   = "Placeholder cost anomaly alarm (C10 driver — actual signal comes from Cost Explorer / skill)"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = 1000000 # effectively never fires; manual demo uses Cost Explorer
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "ecs_cpu"
    return_data = true
    metric {
      metric_name = "CPUUtilization"
      namespace   = "AWS/ECS"
      period      = 300
      stat        = "Sum"
      dimensions = {
        ClusterName = aws_ecs_cluster.china_data.name
      }
    }
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]
}
