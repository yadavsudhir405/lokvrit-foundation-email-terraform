output "mailgun_domain" {
  description = "The Mailgun domain that was provisioned."
  value       = mailgun_domain.this.name
}

output "smtp_login" {
  description = "SMTP login for sending mail through Mailgun (e.g. postmaster@<mail_domain>)."
  value       = mailgun_domain.this.smtp_login
}

output "smtp_password" {
  description = "SMTP password for the Mailgun domain. Retrieve with: terraform output -raw smtp_password"
  value       = random_password.smtp.result
  sensitive   = true
}

output "smtp_server" {
  description = "Mailgun SMTP server host to send through."
  value       = var.mailgun_region == "eu" ? "smtp.eu.mailgun.org" : "smtp.mailgun.org"
}

output "dns_records_created" {
  description = "The DNS records created in GoDaddy for Mailgun."
  value = {
    for k, r in local.dns_records : k => {
      type     = r.type
      name     = r.name
      value    = r.data
      priority = r.priority
    }
  }
}

output "verification_hint" {
  description = "How to confirm the domain is verified once DNS propagates."
  value       = "Run: curl -s --user 'api:$MAILGUN_API_KEY' -X PUT https://api.${var.mailgun_region == "eu" ? "eu." : ""}mailgun.net/v4/domains/${var.mail_domain}/verify"
}
