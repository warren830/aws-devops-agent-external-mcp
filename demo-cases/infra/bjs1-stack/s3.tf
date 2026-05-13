# ----------------------------------------------------------------------------
# S3 uploads bucket — private + KMS encrypted, all public access blocked.
# ----------------------------------------------------------------------------

resource "aws_kms_key" "uploads" {
  description             = "KMS key for bjs-todo-uploads bucket SSE-KMS"
  deletion_window_in_days = 7
  enable_key_rotation     = true
}

resource "aws_kms_alias" "uploads" {
  name          = "alias/bjs-todo-uploads"
  target_key_id = aws_kms_key.uploads.key_id
}

resource "aws_s3_bucket" "uploads" {
  bucket = "bjs-todo-uploads-${local.bucket_suffix}"

  tags = {
    Name = "bjs-todo-uploads"
  }
}

resource "aws_s3_bucket_public_access_block" "uploads" {
  bucket = aws_s3_bucket.uploads.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "uploads" {
  bucket = aws_s3_bucket.uploads.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.uploads.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_versioning" "uploads" {
  bucket = aws_s3_bucket.uploads.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Bucket policy: deny non-TLS access. Plus standard "no public read" implied by
# the public-access-block above.
data "aws_iam_policy_document" "uploads" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.uploads.arn,
      "${aws_s3_bucket.uploads.arn}/*",
    ]
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "uploads" {
  bucket = aws_s3_bucket.uploads.id
  policy = data.aws_iam_policy_document.uploads.json

  # Public-access-block must be in place before the policy lands so
  # there is no momentary window where a buggy policy could go public.
  depends_on = [aws_s3_bucket_public_access_block.uploads]
}
