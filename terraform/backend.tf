# Remote state backend.
#
# Terraform state contains sensitive values (SMTP password, DKIM keys), so it
# MUST live in a private, encrypted, locking backend — never in git.
#
# This is a PARTIAL configuration: bucket/key/region are supplied at
# `terraform init` time via `-backend-config=...` flags (see the GitHub
# workflow and README) so no account-specific values are committed here.
#
# For a quick LOCAL test with no cloud account, comment this whole block out
# and Terraform falls back to local state (terraform/terraform.tfstate).
terraform {
  backend "s3" {
    # Provided via -backend-config at init time:
    #   bucket = "my-tfstate-bucket"
    #   key    = "lokvritfoundation/email/terraform.tfstate"
    #   region = "us-east-1"
    encrypt = true

    # Native S3 state locking (Terraform >= 1.10) — a conditional-write lock
    # file is kept alongside the state object. No DynamoDB table required.
    use_lockfile = true
  }
}
