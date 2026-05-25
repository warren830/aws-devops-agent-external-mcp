# -----------------------------------------------------------------------------
# ECS Task Execution Role — pulls images from ECR + reads secrets from SM.
# ECS Task Role — ambient credentials available inside the container.
# -----------------------------------------------------------------------------

resource "aws_iam_role" "task_execution" {
  name = "${var.name_prefix}-ecs-exec"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "task_execution_base" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_policy" "read_secrets" {
  name = "${var.name_prefix}-ecs-secrets"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = concat(
        [for k, v in local.secret_arns : v],
        var.roles_anywhere != null ? [
          var.roles_anywhere.cert_secret_arn,
          var.roles_anywhere.key_secret_arn,
        ] : []
      )
    }]
  })
}

resource "aws_iam_role_policy_attachment" "task_execution_secrets" {
  role       = aws_iam_role.task_execution.name
  policy_arn = aws_iam_policy.read_secrets.arn
}

# Task role — for containers that need call_kubectl (eks:DescribeCluster for kubeconfig)
resource "aws_iam_role" "task" {
  name = "${var.name_prefix}-ecs-task"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_policy" "eks_describe" {
  name = "${var.name_prefix}-eks-describe"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["eks:DescribeCluster"]
      Resource = "*"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "task_eks" {
  role       = aws_iam_role.task.name
  policy_arn = aws_iam_policy.eks_describe.arn
}
