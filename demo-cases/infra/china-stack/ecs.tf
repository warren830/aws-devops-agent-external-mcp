###############################################################################
# ECS:
# - Cluster `china-data` with Container Insights enabled
# - Service `etl-worker` (Fargate, 0.25 vCPU / 512 MB; container memory 256 MB
#   — DELIBERATELY too small to drive OOM in case C3 / fault L5).
#   NOTE: Fargate task memory minimum at 256 CPU is 512 MB. We achieve the
#   "256 MB OOM" effect by setting the *container*-level memory limit to 256.
# - Service `report-generator` (Fargate, 0.5 vCPU / 1 GB, desired count 0
#   because it is cron-triggered).
###############################################################################

# ----- Security group for ECS Fargate tasks -----
resource "aws_security_group" "ecs_tasks" {
  name        = "${var.name_prefix}-ecs-tasks"
  description = "Egress for china-data ECS Fargate tasks"
  vpc_id      = data.aws_vpc.default.id

  egress {
    description = "All egress (NAT/IGW for SQS / DDB / ECR / S3)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.name_prefix}-ecs-tasks"
  }
}

# ----- Cluster -----
resource "aws_ecs_cluster" "china_data" {
  name = var.name_prefix # "china-data"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

resource "aws_ecs_cluster_capacity_providers" "china_data" {
  cluster_name       = aws_ecs_cluster.china_data.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    base              = 1
    weight            = 100
    capacity_provider = "FARGATE"
  }
}

# ----- Log groups -----
resource "aws_cloudwatch_log_group" "etl_worker" {
  name              = "/ecs/etl-worker"
  retention_in_days = var.log_retention_days
}

resource "aws_cloudwatch_log_group" "report_generator" {
  name              = "/ecs/report-generator"
  retention_in_days = var.log_retention_days
}

# ----- Task definition: etl-worker -----
resource "aws_ecs_task_definition" "etl_worker" {
  family                   = "etl-worker"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = tostring(var.etl_task_cpu)    # "256" => 0.25 vCPU
  memory                   = tostring(var.etl_task_memory) # "512" — Fargate min for 256 cpu
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([
    {
      name      = "etl-worker"
      image     = local.etl_image_resolved
      essential = true

      # Container-level memory limit deliberately smaller than the task
      # memory, to drive OOMKilled behavior for case C3 / fault L5.
      memory            = 256
      memoryReservation = 128

      environment = [
        { name = "ETL_QUEUE_URL", value = aws_sqs_queue.etl_jobs.url },
        { name = "ETL_STATE_TABLE", value = aws_dynamodb_table.etl_state.name },
        { name = "S3_INPUT_BUCKET", value = aws_s3_bucket.input.bucket },
        { name = "S3_OUTPUT_BUCKET", value = aws_s3_bucket.output.bucket },
        { name = "AWS_DEFAULT_REGION", value = local.region },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.etl_worker.name
          awslogs-region        = local.region
          awslogs-stream-prefix = "etl-worker"
        }
      }
    }
  ])
}

# ----- Service: etl-worker -----
resource "aws_ecs_service" "etl_worker" {
  name            = "etl-worker"
  cluster         = aws_ecs_cluster.china_data.id
  task_definition = aws_ecs_task_definition.etl_worker.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = data.aws_subnets.default.ids
    security_groups  = [aws_security_group.ecs_tasks.id]
    assign_public_ip = true # default VPC has IGW; needed to pull from ECR
  }

  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 200

  # Inject scripts (C3, C10) may bump desired_count via aws CLI — don't fight.
  lifecycle {
    ignore_changes = [desired_count]
  }
}

# ----- Task definition: report-generator (cron-style) -----
resource "aws_ecs_task_definition" "report_generator" {
  family                   = "report-generator"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = tostring(var.report_task_cpu)
  memory                   = tostring(var.report_task_memory)
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([
    {
      name      = "report-generator"
      image     = local.report_image_resolved
      essential = true

      environment = [
        { name = "ETL_STATE_TABLE", value = aws_dynamodb_table.etl_state.name },
        { name = "S3_OUTPUT_BUCKET", value = aws_s3_bucket.output.bucket },
        { name = "AWS_DEFAULT_REGION", value = local.region },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.report_generator.name
          awslogs-region        = local.region
          awslogs-stream-prefix = "report-generator"
        }
      }
    }
  ])
}

# ----- Service: report-generator (long-running placeholder, scaled to 0) -----
# Cron-style report-generator: we keep desired_count at 0 in base state and
# rely on a separate scheduler/runtask invocation to launch on demand.
resource "aws_ecs_service" "report_generator" {
  name            = "report-generator"
  cluster         = aws_ecs_cluster.china_data.id
  task_definition = aws_ecs_task_definition.report_generator.arn
  desired_count   = 0
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = data.aws_subnets.default.ids
    security_groups  = [aws_security_group.ecs_tasks.id]
    assign_public_ip = true
  }

  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 200

  lifecycle {
    ignore_changes = [desired_count]
  }
}
