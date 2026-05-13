###############################################################################
# Provider + lookups
###############################################################################
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.4"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  account_id    = data.aws_caller_identity.current.account_id
  partition     = data.aws_partition.current.partition
  region        = data.aws_region.current.region
  function_name = var.name_prefix

  ssm_url_param_name    = "${var.ssm_parameter_prefix}/webhook-url"
  ssm_secret_param_name = "${var.ssm_parameter_prefix}/webhook-secret"

  ssm_url_param_arn    = "arn:${local.partition}:ssm:${local.region}:${local.account_id}:parameter${local.ssm_url_param_name}"
  ssm_secret_param_arn = "arn:${local.partition}:ssm:${local.region}:${local.account_id}:parameter${local.ssm_secret_param_name}"
}

###############################################################################
# Package the Lambda code
###############################################################################
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../src"
  output_path = "${path.module}/build/handler.zip"
}

###############################################################################
# IAM
###############################################################################
data "aws_iam_policy_document" "assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = "${local.function_name}-role"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
  tags               = var.tags
}

# Logs (scoped to this function's log group).
data "aws_iam_policy_document" "logs" {
  statement {
    sid    = "Logs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = [
      "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:/aws/lambda/${local.function_name}:*",
      "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:/aws/lambda/${local.function_name}",
    ]
  }
  statement {
    sid       = "LogsCreateGroup"
    effect    = "Allow"
    actions   = ["logs:CreateLogGroup"]
    resources = ["arn:${local.partition}:logs:${local.region}:${local.account_id}:*"]
  }
}

# SSM read on the two webhook parameters only.
data "aws_iam_policy_document" "ssm" {
  statement {
    sid    = "ReadWebhookParameters"
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
    ]
    resources = [
      local.ssm_url_param_arn,
      local.ssm_secret_param_arn,
    ]
  }
}

# KMS decrypt on the SecureString's key.
data "aws_iam_policy_document" "kms" {
  statement {
    sid     = "DecryptSecureStringSecret"
    effect  = "Allow"
    actions = ["kms:Decrypt"]

    # If a CMK ARN is given, scope to it. Otherwise allow decrypt only when
    # invoked via SSM (the AWS-managed alias/aws/ssm key).
    resources = var.ssm_secret_kms_key_arn != null ? [var.ssm_secret_kms_key_arn] : ["*"]

    dynamic "condition" {
      for_each = var.ssm_secret_kms_key_arn == null ? [1] : []
      content {
        test     = "StringEquals"
        variable = "kms:ViaService"
        values   = ["ssm.${local.region}.amazonaws.com.cn", "ssm.${local.region}.amazonaws.com"]
      }
    }
  }
}

# CloudWatch ListTagsForResource (used to read alarm Priority tag).
# Tag-based authz: scope to alarm resources in this region/account.
data "aws_iam_policy_document" "cloudwatch_tags" {
  statement {
    sid       = "ReadAlarmTags"
    effect    = "Allow"
    actions   = ["cloudwatch:ListTagsForResource"]
    resources = ["arn:${local.partition}:cloudwatch:${local.region}:${local.account_id}:alarm:*"]
  }
}

resource "aws_iam_role_policy" "logs" {
  name   = "logs"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.logs.json
}

resource "aws_iam_role_policy" "ssm" {
  name   = "ssm-read-webhook"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.ssm.json
}

resource "aws_iam_role_policy" "kms" {
  name   = "kms-decrypt-secret"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.kms.json
}

resource "aws_iam_role_policy" "cloudwatch_tags" {
  name   = "cloudwatch-list-tags"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.cloudwatch_tags.json
}

###############################################################################
# Log group (managed explicitly so we control retention)
###############################################################################
resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${local.function_name}"
  retention_in_days = var.lambda_log_retention_days
  tags              = var.tags
}

###############################################################################
# Lambda function
###############################################################################
resource "aws_lambda_function" "bridge" {
  function_name    = local.function_name
  role             = aws_iam_role.lambda.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  memory_size      = var.lambda_memory_mb
  timeout          = var.lambda_timeout_seconds

  environment {
    variables = {
      SSM_PARAMETER_PREFIX = var.ssm_parameter_prefix
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.lambda,
    aws_iam_role_policy.logs,
    aws_iam_role_policy.ssm,
    aws_iam_role_policy.kms,
    aws_iam_role_policy.cloudwatch_tags,
  ]

  tags = var.tags
}

###############################################################################
# SNS subscriptions (one per topic ARN supplied)
###############################################################################
resource "aws_lambda_permission" "sns" {
  for_each = toset(var.sns_topic_arns)

  statement_id  = "AllowSNSInvoke-${replace(each.value, "/[^a-zA-Z0-9]/", "-")}"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.bridge.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = each.value
}

resource "aws_sns_topic_subscription" "bridge" {
  for_each = toset(var.sns_topic_arns)

  topic_arn = each.value
  protocol  = "lambda"
  endpoint  = aws_lambda_function.bridge.arn

  depends_on = [aws_lambda_permission.sns]
}
