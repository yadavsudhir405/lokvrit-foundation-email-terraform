terraform {
  required_version = ">= 1.5.0"

  required_providers {
    mailgun = {
      source  = "wgebis/mailgun"
      version = "~> 0.7"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}
