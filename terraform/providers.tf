provider "mailgun" {
  api_key = var.mailgun_api_key
}

# The godaddy-dns provider reads credentials from the environment:
#   GODADDY_API_KEY / GODADDY_API_SECRET
# (set as GitHub secrets in the workflow). No arguments needed here.
provider "godaddy-dns" {}

provider "random" {}
