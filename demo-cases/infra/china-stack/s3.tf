###############################################################################
# S3 buckets — both PRIVATE in base state.
#
# - china-data-output-<suffix>: BASE = private. C10/L2 inject script will
#   toggle public access block off + put a public read policy. Terraform
#   ignore_changes prevents drift fighting.
#
# - china-data-input-<suffix>: stays private + KMS-encrypted forever.
###############################################################################

# ----- KMS key for input bucket -----
resource "aws_kms_key" "s3_input" {
  description             = "KMS key for china-data-input bucket"
  deletion_window_in_days = 7
  enable_key_rotation     = true
}

resource "aws_kms_alias" "s3_input" {
  name          = "alias/china-data-input"
  target_key_id = aws_kms_key.s3_input.key_id
}

# ----- Output bucket (PRIVATE in base state; C10 inject toggles to public) -----
resource "aws_s3_bucket" "output" {
  bucket = "china-data-output-${random_id.suffix.hex}"

  tags = {
    Name    = "china-data-output"
    Purpose = "etl-output (fault-target for C10 / L2)"
  }
}

resource "aws_s3_bucket_ownership_controls" "output" {
  bucket = aws_s3_bucket.output.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "output" {
  bucket = aws_s3_bucket.output.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  # The C10/L2 inject script toggles this. Don't let TF fight back.
  lifecycle {
    ignore_changes = all
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "output" {
  bucket = aws_s3_bucket.output.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "output" {
  bucket = aws_s3_bucket.output.id
  versioning_configuration {
    status = "Disabled"
  }
}

# ----- Input bucket (always private + KMS) -----
resource "aws_s3_bucket" "input" {
  bucket = "china-data-input-${random_id.suffix.hex}"

  tags = {
    Name    = "china-data-input"
    Purpose = "etl-input (private + KMS)"
  }
}

resource "aws_s3_bucket_ownership_controls" "input" {
  bucket = aws_s3_bucket.input.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "input" {
  bucket = aws_s3_bucket.input.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "input" {
  bucket = aws_s3_bucket.input.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.s3_input.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_versioning" "input" {
  bucket = aws_s3_bucket.input.id
  versioning_configuration {
    status = "Enabled"
  }
}
