# -----------------------------------------------------------------------------
# ECS Cluster + per-account Fargate Services
#
# Adding a new MCP account:
#   auth_mode = "ak_sk":
#     1. Add entry to var.accounts with access_key/secret_key
#     2. Add DNS CNAME pointing host → ALB DNS name
#     3. terraform apply
#
#   auth_mode = "roles_anywhere":
#     1. Deploy cfn/roles-anywhere-spoke.yaml in the target account
#     2. Add entry to var.accounts with spoke_role_arn
#     3. Add DNS CNAME pointing host → ALB DNS name
#     4. terraform apply
# -----------------------------------------------------------------------------

resource "aws_ecs_cluster" "mcp" {
  name = var.name_prefix

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

resource "aws_ecs_cluster_capacity_providers" "mcp" {
  cluster_name       = aws_ecs_cluster.mcp.name
  capacity_providers = ["FARGATE"]

  default_capacity_provider_strategy {
    base              = 1
    weight            = 100
    capacity_provider = "FARGATE"
  }
}

# ----- Security group for Fargate tasks -----
resource "aws_security_group" "tasks" {
  name        = "${var.name_prefix}-tasks"
  description = "Allow ALB to reach Fargate tasks"
  vpc_id      = local.vpc_id

  ingress {
    description     = "HTTP from ALB"
    from_port       = 8000
    to_port         = 8000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ----- CloudWatch Log Groups -----
resource "aws_cloudwatch_log_group" "mcp" {
  for_each          = var.accounts
  name              = "/ecs/${var.name_prefix}-${each.key}"
  retention_in_days = 14
}

# ----- Task Definitions -----
resource "aws_ecs_task_definition" "mcp" {
  for_each = var.accounts

  family                   = "${var.name_prefix}-${each.key}"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([{
    name      = "mcp"
    image     = "${local.ecr_urls[each.value.provider]}:${var.images[each.value.provider].tag}"
    essential = true

    command = (
      each.value.provider == "aliyun"
        ? ["python", "-m", "alibaba_cloud_ops_mcp_server",
           "--transport", "streamable-http",
           "--host", "0.0.0.0",
           "--port", "8000",
           "--env", each.value.aliyun_env]
        : each.value.auth_mode == "roles_anywhere"
          ? ["/app/entrypoint-ra.sh"]
          : each.value.use_entrypoint
            ? ["python", "/app/entrypoint.py"]
            : ["python", "-m", "awslabs.aws_api_mcp_server.server"]
    )

    environment = (
      each.value.provider == "aliyun"
      ? []
      : concat(
          [
            { name = "AWS_API_MCP_TRANSPORT", value = "streamable-http" },
            { name = "AWS_API_MCP_STATELESS_HTTP", value = "true" },
            { name = "AWS_API_MCP_HOST", value = "0.0.0.0" },
            { name = "AWS_API_MCP_PORT", value = "8000" },
            { name = "AUTH_TYPE", value = "no-auth" },
            { name = "AWS_API_MCP_ALLOWED_HOSTS", value = each.value.host },
            { name = "AWS_API_MCP_ALLOWED_ORIGINS", value = each.value.host },
            { name = "AWS_DEFAULT_REGION", value = each.value.aws_region },
          ],
          each.value.use_entrypoint ? [
            { name = "EKS_CLUSTER_NAME", value = each.value.eks_cluster },
            { name = "EKS_REGION", value = each.value.eks_region },
          ] : [],
          each.value.auth_mode == "roles_anywhere" ? [
            { name = "RA_CERT_PATH", value = "/app/certs/client.crt" },
            { name = "RA_KEY_PATH", value = "/app/certs/client.key" },
            { name = "RA_TRUST_ANCHOR_ARN", value = var.roles_anywhere.trust_anchor_arn },
            { name = "RA_PROFILE_ARN", value = var.roles_anywhere.profile_arn },
            { name = "RA_HUB_ROLE_ARN", value = var.roles_anywhere.hub_role_arn },
            { name = "RA_SPOKE_ROLE_ARN", value = each.value.spoke_role_arn },
            { name = "RA_REGION", value = var.roles_anywhere.region },
            { name = "RA_EXTERNAL_ID", value = var.roles_anywhere.external_id },
          ] : []
        )
    )

    secrets = (
      each.value.provider == "aliyun"
      ? [
          { name = "ALIBABA_CLOUD_ACCESS_KEY_ID", valueFrom = "${local.secret_arns[each.key]}:AK::" },
          { name = "ALIBABA_CLOUD_ACCESS_KEY_SECRET", valueFrom = "${local.secret_arns[each.key]}:SK::" },
        ]
      : each.value.auth_mode == "roles_anywhere"
        ? [
            { name = "RA_CERT_PEM", valueFrom = var.roles_anywhere.cert_secret_arn },
            { name = "RA_KEY_PEM", valueFrom = var.roles_anywhere.key_secret_arn },
          ]
        : [
            { name = "AWS_ACCESS_KEY_ID", valueFrom = "${local.secret_arns[each.key]}:AK::" },
            { name = "AWS_SECRET_ACCESS_KEY", valueFrom = "${local.secret_arns[each.key]}:SK::" },
          ]
    )

    portMappings = [{ containerPort = 8000, protocol = "tcp" }]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = "/ecs/${var.name_prefix}-${each.key}"
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "mcp"
      }
    }
  }])
}

# ----- Target Groups -----
resource "aws_lb_target_group" "mcp" {
  for_each = var.accounts

  name        = "${var.name_prefix}-${each.key}"
  port        = 8000
  protocol    = "HTTP"
  vpc_id      = local.vpc_id
  target_type = "ip"

  health_check {
    path                = "/mcp"
    matcher             = "200-405"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

# ----- ALB Listener Rules (host-based routing) -----
resource "aws_lb_listener_rule" "mcp" {
  for_each = var.accounts

  listener_arn = aws_lb_listener.https.arn

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.mcp[each.key].arn
  }

  condition {
    host_header {
      values = [each.value.host]
    }
  }
}

# ----- ECS Services -----
resource "aws_ecs_service" "mcp" {
  for_each = var.accounts

  name            = "${var.name_prefix}-${each.key}"
  cluster         = aws_ecs_cluster.mcp.id
  task_definition = aws_ecs_task_definition.mcp[each.key].arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = local.private_subnet_ids
    security_groups  = [aws_security_group.tasks.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.mcp[each.key].arn
    container_name   = "mcp"
    container_port   = 8000
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }
}
