# lokvritfoundation.org — Email infrastructure (Mailgun + GoDaddy) as code

Terraform + GitHub Actions to stand up email for the domain — **sending**
(SPF/DKIM/tracking) and **receiving** (MX + inbound forwarding routes) —
through [Mailgun](https://www.mailgun.com/), with all DNS records managed in
GoDaddy.

> **Domain name:** everything defaults to `lokvritfoundation.org` (matches the
> repo/folder name and the `info@lokvritfoundation.org` example). If your
> registered domain is actually `lokfoundation.org`, change `root_domain` and
> `mail_domain` in `terraform/terraform.tfvars`.

## What it creates

| Where    | Resource | Purpose |
|----------|----------|---------|
| Mailgun  | `mailgun_domain` | Sending domain + DKIM keypair + SMTP creds |
| GoDaddy  | `godaddy-dns_record` (TXT) | SPF record — authorizes Mailgun to send |
| GoDaddy  | `godaddy-dns_record` (TXT) | DKIM record — signs outgoing mail |
| GoDaddy  | `godaddy-dns_record` (CNAME) | Open/click tracking (`email.<domain>`) |
| GoDaddy  | `godaddy-dns_record` (MX) | Route inbound mail to Mailgun |
| Mailgun  | `mailgun_route` | Forward `info@…` (etc.) to a real mailbox |

The Mailgun-required DNS records are read straight from the Mailgun resource's
`sending_records_set` / `receiving_records_set` outputs and materialized in
GoDaddy — so there's no copy/paste and the two stay in sync.

## Prerequisites

1. **Mailgun account** and a **private API key**
   (Dashboard → *Send* → *API keys*). Note your region (**US** or **EU**) — it
   must match `mailgun_region`.
2. **GoDaddy production API key + secret** from
   <https://developer.godaddy.com/keys>.
   > GoDaddy restricted its DNS API in 2024; as of the latest policy it works
   > for accounts with **≥ 1 domain**, so a single-domain account is fine.
   > Create a **Production** key (not OTE), since OTE won't touch your real DNS.
3. An existing mailbox to forward inbound mail to (e.g. a Gmail address). On
   Mailgun's free plan, forward destinations must be *authorized recipients*.
4. For CI remote state: an **S3 bucket** (state locking is handled natively by
   the S3 backend — no DynamoDB needed), or comment out `terraform/backend.tf`
   to use local state.

## One-time: create the state bucket (manual)

Remote state lives in an S3 bucket. It can't be created by this config (the
config's `terraform init` needs the bucket to already exist), so create it
**once, by hand**, then point Terraform at it. Pick a globally-unique name:

```bash
BUCKET=lokvritfoundation-tfstate
REGION=ap-south-1

# Create the bucket (us-east-1 omits the LocationConstraint flag).
aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
  --create-bucket-configuration LocationConstraint="$REGION"

# Recommended hardening:
aws s3api put-bucket-versioning --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket "$BUCKET" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
aws s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

Then set the GitHub variable `TF_STATE_BUCKET` to this bucket name (and
`AWS_REGION` to the region). State locking is handled natively by the S3
backend (`use_lockfile = true`) — no DynamoDB needed. Versioning lets you
recover a previous state if an apply corrupts it.

## Local usage

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # edit domain + forward routes

export TF_VAR_mailgun_api_key="key-xxxxxxxxxxxxxxxx"
export GODADDY_API_KEY="xxxx"
export GODADDY_API_SECRET="xxxx"

# Local state (skip -backend-config); or configure S3 as in the workflow.
terraform init
terraform plan
terraform apply
```

After apply, retrieve sending credentials:

```bash
terraform output smtp_login
terraform output -raw smtp_password
terraform output smtp_server
```

## Sending as info@lokvritfoundation.org

Use the Mailgun **API** with an explicit `from`, or **SMTP** with the domain
credentials above. API example:

```bash
curl -s --user "api:$TF_VAR_mailgun_api_key" \
  https://api.mailgun.net/v3/lokvritfoundation.org/messages \
  -F from='Lokvrit Foundation <info@lokvritfoundation.org>' \
  -F to='someone@example.com' \
  -F subject='Hello' \
  -F text='Sent via Mailgun.'
```

(Use `api.eu.mailgun.net` for the EU region.)

## Receiving mail

Inbound mail to addresses matched by `forward_routes` is forwarded to the
destination mailbox. Add more addresses by extending `forward_routes` in
`terraform.tfvars`. Optionally set `store_and_notify_url` to store messages in
Mailgun and POST a webhook instead.

## Domain verification

DNS propagation can take minutes to hours. Verification is triggered
automatically after `apply` in CI (and is best-effort). To trigger manually:

```bash
curl -s --user "api:$TF_VAR_mailgun_api_key" \
  -X PUT https://api.mailgun.net/v4/domains/lokvritfoundation.org/verify
```

Re-run until the domain shows `state: active`.

## CI/CD — GitHub Actions

`.github/workflows/email-deploy.yml` runs Terraform in `terraform/` against the
S3 backend. It triggers two ways:

- **Push to `main`** (touching `terraform/`) → **applies automatically**.
- **Manual** (Actions tab → *email-deploy* → *Run workflow*) → choose `plan`
  (preview, default) or `apply`.

After any apply it triggers a best-effort Mailgun domain verify.

Prerequisite: the state bucket must already exist (see *One-time: create the
state bucket* above).

### Required GitHub configuration

**Secrets** (Settings → Secrets and variables → Actions → *Secrets*):

| Secret | Value |
|--------|-------|
| `MAILGUN_API_KEY` | Mailgun private API key |
| `GODADDY_API_KEY` | GoDaddy production API key |
| `GODADDY_API_SECRET` | GoDaddy production API secret |
| `AWS_ACCESS_KEY_ID` | AWS credential with access to the state bucket |
| `AWS_SECRET_ACCESS_KEY` | AWS credential |

**Variables** (*Variables* tab):

| Variable | Example |
|----------|---------|
| `AWS_REGION` | `us-east-1` |
| `TF_STATE_BUCKET` | `my-tfstate-bucket` |
| `MAILGUN_REGION` | `us` or `eu` |

Non-secret Terraform inputs (domain, routes) are committed in
`terraform/terraform.tfvars`. Secrets are injected via `TF_VAR_*` / provider
env vars and never written to disk.

## Notes & gotchas

- **State is sensitive** (DKIM private material, SMTP password). Keep the S3
  bucket private + encrypted; never commit `*.tfstate`.
- **DKIM size:** default `1024` keeps the TXT record under the 255-char DNS
  limit. `2048` is stronger but the record may need splitting — verify a clean
  apply before switching.
- **Apex MX:** with `mail_domain == root_domain`, all mail for the domain flows
  to Mailgun. Use a subdomain (`mg.…`) if you need the apex for another
  provider.
- **Provider docs:** [wgebis/mailgun](https://registry.terraform.io/providers/wgebis/mailgun/latest/docs)
  · [veksh/godaddy-dns](https://registry.terraform.io/providers/veksh/godaddy-dns/latest/docs)
```
