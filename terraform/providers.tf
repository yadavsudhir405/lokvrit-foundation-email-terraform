provider "mailgun" {
  api_key = var.mailgun_api_key
}

# AWS is used for Route 53 (DNS) and the S3 state backend. Credentials come
# from the environment: AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY (GitHub
# secrets), and the region from AWS_REGION / var.aws_region.
provider "aws" {
  region = var.aws_region
}

provider "random" {}
