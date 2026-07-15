terraform {
  required_version = ">= 1.5.0"

  required_providers {
    mailgun = {
      source  = "wgebis/mailgun"
      version = "~> 0.7"
    }
    godaddy-dns = {
      source  = "veksh/godaddy-dns"
      version = "~> 0.3"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}
