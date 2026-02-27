# Remote state in S3 — bucket and region are set via -backend-config at init time:
#
#   terraform init \
#     -backend-config="bucket=YOUR_BUCKET_NAME" \
#     -backend-config="region=YOUR_BUCKET_REGION"
#
terraform {
  backend "s3" {
    key          = "cloudops_crm/terraform.tfstate"
    use_lockfile = true # S3-native locking (no DynamoDB needed)
    encrypt      = true
  }
}
