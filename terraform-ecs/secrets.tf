# -----------------------------------------------------------------------------
# Secrets Manager — conditional based on auth_mode.
#
# ak_sk accounts:          one secret per account with {"AK":"...","SK":"..."}
# roles_anywhere accounts: no per-account secret; uses shared cert/key from var.roles_anywhere
# -----------------------------------------------------------------------------

locals {
  ak_sk_accounts = { for k, v in var.accounts : k => v if v.auth_mode == "ak_sk" }
  ra_accounts    = { for k, v in var.accounts : k => v if v.auth_mode == "roles_anywhere" }
}

resource "aws_secretsmanager_secret" "mcp" {
  for_each = local.ak_sk_accounts
  name     = "/mcp/${each.key}"
}

resource "aws_secretsmanager_secret_version" "mcp" {
  for_each  = local.ak_sk_accounts
  secret_id = aws_secretsmanager_secret.mcp[each.key].id
  secret_string = jsonencode({
    AK = each.value.access_key
    SK = each.value.secret_key
  })
}

locals {
  secret_arns = { for k, v in aws_secretsmanager_secret.mcp : k => v.arn }
}
