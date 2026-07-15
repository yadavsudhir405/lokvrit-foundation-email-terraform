# ---------------------------------------------------------------------------
# 1. SMTP password for the Mailgun domain (used when sending via SMTP).
# ---------------------------------------------------------------------------
resource "random_password" "smtp" {
  length  = 24
  special = false # keep it SMTP/URL friendly
}

# ---------------------------------------------------------------------------
# 2. Mailgun domain — provisions sending (SPF/DKIM/tracking) and receiving (MX)
#    configuration. After the DNS records below exist and propagate, Mailgun
#    verifies the domain (triggered by the "verify" step in the CI pipeline).
# ---------------------------------------------------------------------------
resource "mailgun_domain" "this" {
  name          = var.mail_domain
  region        = var.mailgun_region
  smtp_password = random_password.smtp.result
  dkim_key_size = var.dkim_key_size
  spam_action   = "disabled"

  # Accept mail for the domain itself (needed for receiving at the apex).
  wildcard = false
}

# ---------------------------------------------------------------------------
# 3. Create Mailgun's required DNS records in Route 53.
#
#    The hosted zone is assumed to already exist (GoDaddy delegates its
#    nameservers to it). Mailgun returns fully-qualified record names, which
#    Route 53 uses directly — no zone-suffix stripping needed.
#
#    Route 53 groups records by (name, type), so multi-value records such as
#    the two MX entries must live in a single resource with a list of values.
# ---------------------------------------------------------------------------
data "aws_route53_zone" "this" {
  name         = var.root_domain
  private_zone = false
}

locals {
  # Sending records: SPF (TXT), DKIM (TXT), tracking (CNAME). Names are FQDNs.
  sending_flat = [
    for r in mailgun_domain.this.sending_records_set : {
      type  = r.record_type
      name  = r.name
      value = r.value
    }
  ]

  # Receiving records: MX. In Route 53 the priority is part of the record
  # value ("10 mxa.mailgun.org"), not a separate field. All MX sit on the
  # mail domain.
  receiving_flat = [
    for r in mailgun_domain.this.receiving_records_set : {
      type  = r.record_type
      name  = var.mail_domain
      value = "${r.priority} ${r.value}"
    }
  ]

  all_flat = concat(local.sending_flat, local.receiving_flat)

  # Group into one entry per (type, name), collecting all values into a list.
  record_keys = distinct([for r in local.all_flat : "${r.type}|${r.name}"])
  dns_records = {
    for k in local.record_keys : k => {
      type   = split("|", k)[0]
      name   = split("|", k)[1]
      values = [for r in local.all_flat : r.value if "${r.type}|${r.name}" == k]
    }
  }
}

resource "aws_route53_record" "mailgun" {
  for_each = local.dns_records

  zone_id = data.aws_route53_zone.this.zone_id
  name    = each.value.name
  type    = each.value.type
  ttl     = var.record_ttl
  records = each.value.values
}

# ---------------------------------------------------------------------------
# 4. Inbound routes — forward received mail to real mailboxes.
#    (Routes are matched globally in Mailgun; they only fire once the domain
#     is verified and MX records point at Mailgun.)
# ---------------------------------------------------------------------------
resource "mailgun_route" "forward" {
  for_each = {
    for idx, r in var.forward_routes : "${r.recipient}=>${r.destination}" => r
  }

  region      = var.mailgun_region
  priority    = each.value.priority
  description = each.value.description != "" ? each.value.description : "Forward ${each.value.recipient} -> ${each.value.destination}"
  expression  = "match_recipient('${each.value.recipient}')"

  actions = [
    "forward('${each.value.destination}')",
    "stop()",
  ]
}

# Optional: store every inbound message in Mailgun and notify a webhook.
resource "mailgun_route" "store_and_notify" {
  count = var.store_and_notify_url != "" ? 1 : 0

  region      = var.mailgun_region
  priority    = 100
  description = "Catch-all: store and notify"
  expression  = "match_recipient('.*@${var.mail_domain}')"

  actions = [
    "store(notify='${var.store_and_notify_url}')",
    "stop()",
  ]
}
