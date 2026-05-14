data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "dns_lab_scripts" {
  bucket        = "dns-lab-scripts-${data.aws_caller_identity.current.account_id}"
  force_destroy = true

  tags = { Name = "dns-lab-scripts" }
}

resource "aws_s3_bucket_public_access_block" "dns_lab_scripts" {
  bucket                  = aws_s3_bucket.dns_lab_scripts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_object" "chronicled_install" {
  bucket = aws_s3_bucket.dns_lab_scripts.id
  key    = "chronicled-install.sh"
  source = "${path.module}/chronicled-install.sh"
  etag   = filemd5("${path.module}/chronicled-install.sh")
}
