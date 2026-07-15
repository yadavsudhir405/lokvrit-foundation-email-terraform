variable "root_domain" {
  description = "The domain registered in GoDaddy (the DNS zone). e.g. lokvritfoundation.org"
  type        = string
  default     = "lokvritfoundation.org"
}

variable "mail_domain" {
  description = <<-EOT
    The domain Mailgun manages for sending/receiving. Set it equal to
    root_domain to send/receive at the apex (info@lokvritfoundation.org), or to
    a subdomain such as "mg.lokvritfoundation.org" to keep the apex clean.
    Must be root_domain or a subdomain of it.
  EOT
  type        = string
  default     = "lokvritfoundation.org"
}

variable "mailgun_region" {
  description = "Mailgun region: 'us' or 'eu'. Must match the region of your Mailgun account/domain."
  type        = string
  default     = "us"

  validation {
    condition     = contains(["us", "eu"], var.mailgun_region)
    error_message = "mailgun_region must be either 'us' or 'eu'."
  }
}

variable "mailgun_api_key" {
  description = "Mailgun private API key. Supplied via TF_VAR_mailgun_api_key (GitHub secret)."
  type        = string
  sensitive   = true
}

variable "dkim_key_size" {
  description = <<-EOT
    DKIM key size. 1024 keeps the TXT record under the 255-char DNS limit
    (safe for all resolvers). 2048 is stronger but the record may need to be
    split into multiple strings — verify it applies cleanly before switching.
  EOT
  type        = number
  default     = 1024

  validation {
    condition     = contains([1024, 2048], var.dkim_key_size)
    error_message = "dkim_key_size must be 1024 or 2048."
  }
}

variable "record_ttl" {
  description = "TTL (seconds) for the DNS records created in GoDaddy. GoDaddy minimum is 600."
  type        = number
  default     = 3600

  validation {
    condition     = var.record_ttl >= 600 && var.record_ttl <= 604800
    error_message = "record_ttl must be between 600 and 604800 seconds."
  }
}

variable "forward_routes" {
  description = <<-EOT
    Inbound routes. Each entry forwards mail for `recipient` to `destination`
    (an existing mailbox you already own, e.g. a Gmail address). Lower
    `priority` wins. Set destination to a real inbox before applying — Mailgun
    only delivers forwards to verified/authorized recipients on the free plan.
  EOT
  type = list(object({
    recipient   = string # full address, e.g. "info@lokvritfoundation.org"
    destination = string # where to forward, e.g. "you@gmail.com"
    priority    = optional(number, 10)
    description = optional(string, "")
  }))
  default = []
}

variable "store_and_notify_url" {
  description = <<-EOT
    Optional. If set, a catch-all route stores each inbound message in Mailgun
    and POSTs a notification to this URL (webhook). Leave empty to disable.
  EOT
  type        = string
  default     = ""
}
