# -----------------------------------------------------------------------------
# Secrets Manager — one secret per account, auto-created from var.accounts.
# Stores {"AK":"...","SK":"..."} which ECS Task Definition reads via valueFrom.
# -----------------------------------------------------------------------------

resource "aws_secretsmanager_secret" "mcp" {
  for_each = var.accounts
  name     = "/mcp/${each.key}"
}

resource "aws_secretsmanager_secret_version" "mcp" {
  for_each  = var.accounts
  secret_id = aws_secretsmanager_secret.mcp[each.key].id
  secret_string = jsonencode({
    AK = each.value.access_key
    SK = each.value.secret_key
  })
}

locals {
  secret_arns = { for k, v in aws_secretsmanager_secret.mcp : k => v.arn }
}
