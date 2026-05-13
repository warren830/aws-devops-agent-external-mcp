# ----------------------------------------------------------------------------
# CloudWatch alarms + SNS topic
#
# These alarms are wired to a single SNS topic `bjs-web-alarms`. In Phase 2 a
# webhook bridge Lambda will subscribe to this topic and forward to the
# us-east-1 DevOps Agent webhook. For now, only the topic ARN is referenced
# in `alarm_actions` — there is no subscription yet.
# ----------------------------------------------------------------------------

resource "aws_sns_topic" "alarms" {
  name = "bjs-web-alarms"

  tags = {
    Name = "bjs-web-alarms"
  }
}

# ---- C1 driver: pod-not-ready alarm -----------------------------------------
# Uses Container Insights metric `pod_status_phase_pending` published by the
# CloudWatch agent under namespace ContainerInsights, dimensioned by ClusterName.
# When the L6 fault (bad image tag → ImagePullBackOff) is injected, pods stay
# Pending and this alarm fires within ~1 minute.
resource "aws_cloudwatch_metric_alarm" "pod_not_ready" {
  alarm_name          = "bjs-web-pod-not-ready"
  alarm_description   = "Driver for C1: at least one pod stuck Pending in cluster ${var.cluster_name}"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  threshold           = 1
  treat_missing_data  = "notBreaching"

  metric_name = "pod_status_phase_pending"
  namespace   = "ContainerInsights"
  period      = 60
  statistic   = "Maximum"

  dimensions = {
    ClusterName = aws_eks_cluster.this.name
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]
}

# ---- C2 / C9 driver: ALB p99 latency alarm ----------------------------------
# Note: the actual ALB will be created by the Phase-2 Helm chart through the
# ALB controller (Ingress with internal scheme). The chart will tag the ALB
# with `LoadBalancer = bjs-web` so this alarm matches it via dimension.
# Until the ALB exists the alarm will sit in INSUFFICIENT_DATA — which is fine.
resource "aws_cloudwatch_metric_alarm" "alb_p99_latency_high" {
  alarm_name          = "bjs-web-p99-latency-high"
  alarm_description   = "Driver for C2/C9: ALB p99 TargetResponseTime > 500ms"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = 0.5
  treat_missing_data  = "notBreaching"

  metric_name        = "TargetResponseTime"
  namespace          = "AWS/ApplicationELB"
  period             = 60
  extended_statistic = "p99"

  # Dimension placeholder. Phase 2 deploy script will update or recreate this
  # alarm with the actual ALB ARN suffix once the Ingress provisions the LB.
  dimensions = {
    LoadBalancer = "app/bjs-web/placeholder"
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]
}

# ---- C4 driver: ALB 5XX rate alarm ------------------------------------------
resource "aws_cloudwatch_metric_alarm" "alb_5xx_rate_high" {
  alarm_name          = "bjs-web-alb-5xx-rate-high"
  alarm_description   = "Driver for C4: ALB ELB-side 5XX count > 5/min"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = 5
  treat_missing_data  = "notBreaching"

  metric_name = "HTTPCode_ELB_5XX_Count"
  namespace   = "AWS/ApplicationELB"
  period      = 60
  statistic   = "Sum"

  dimensions = {
    LoadBalancer = "app/bjs-web/placeholder"
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]
}

# ---- Log group for the EKS app ----------------------------------------------
# Pre-created with 30-day retention so cost stays bounded. The chart can then
# write to this group from fluent-bit without lazy-creating an unbounded one.
resource "aws_cloudwatch_log_group" "bjs_web_app" {
  name              = "/aws/eks/${var.cluster_name}/application"
  retention_in_days = 30
}
