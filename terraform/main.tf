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
# 3. Translate Mailgun's required DNS records into GoDaddy records.
#
#    Mailgun returns fully-qualified record names; GoDaddy expects names
#    relative to the zone ("@" for the apex). We strip the zone suffix.
# ---------------------------------------------------------------------------
locals {
  zone_suffix = ".${var.root_domain}"

  # Relative name of the mail domain within the zone.
  mail_relative = (
    var.mail_domain == var.root_domain
    ? "@"
    : trimsuffix(var.mail_domain, local.zone_suffix)
  )

  # Sending records: SPF (TXT), DKIM (TXT), tracking (CNAME). These carry a
  # `name` field (an FQDN) that we convert to a zone-relative name.
  sending_records = {
    for r in mailgun_domain.this.sending_records_set :
    "${r.record_type}:${r.name}" => {
      type     = r.record_type
      name     = r.name == var.root_domain ? "@" : trimsuffix(r.name, local.zone_suffix)
      data     = r.value
      priority = null
    }
  }

  # Receiving records: MX records for the mail domain. These have no `name`
  # field (they always sit on the mail domain), but they carry a `priority`.
  receiving_records = {
    for idx, r in mailgun_domain.this.receiving_records_set :
    "MX:${idx}:${r.value}" => {
      type     = r.record_type
      name     = local.mail_relative
      data     = r.value
      priority = tonumber(r.priority)
    }
  }

  dns_records = merge(local.sending_records, local.receiving_records)
}

resource "godaddy-dns_record" "mailgun" {
  for_each = local.dns_records

  domain   = var.root_domain
  type     = each.value.type
  name     = each.value.name
  data     = each.value.data
  ttl      = var.record_ttl
  priority = each.value.priority
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
