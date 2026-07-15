# lokvritfoundation.org — Email infrastructure (Mailgun + Route 53) as code

Terraform + GitHub Actions to stand up email for the domain — **sending**
(SPF/DKIM/tracking) and **receiving** (MX + inbound forwarding routes) —
through [Mailgun](https://www.mailgun.com/), with all DNS records managed in
**AWS Route 53**. The domain is *registered* at GoDaddy, but its nameservers
are delegated to a Route 53 hosted zone, which is authoritative for DNS.

> **Domain name:** everything defaults to `lokvritfoundation.org` (matches the
> repo/folder name and the `info@lokvritfoundation.org` example). If your
> registered domain is actually `lokfoundation.org`, change `root_domain` and
> `mail_domain` in `terraform/terraform.tfvars`.

## What it creates

| Where     | Resource | Purpose |
|-----------|----------|---------|
| Mailgun   | `mailgun_domain` | Sending domain + DKIM keypair + SMTP creds |
| Route 53  | `aws_route53_record` (TXT) | SPF record — authorizes Mailgun to send |
| Route 53  | `aws_route53_record` (TXT) | DKIM record — signs outgoing mail |
| Route 53  | `aws_route53_record` (CNAME) | Open/click tracking (`email.<domain>`) |
| Route 53  | `aws_route53_record` (MX) | Route inbound mail to Mailgun |
| Mailgun   | `mailgun_route` | Forward `info@…` (etc.) to a real mailbox |

The hosted zone is looked up with a `data "aws_route53_zone"` (it must already
exist). The Mailgun-required DNS records are read straight from the Mailgun
resource's `sending_records_set` / `receiving_records_set` outputs and created
in Route 53 — no copy/paste, and the two stay in sync.

## Prerequisites

1. **Mailgun account** and a **private API key**
   (Dashboard → *Send* → *API keys*). Note your region (**US** or **EU**) — it
   must match `mailgun_region`.
2. **A Route 53 hosted zone** for the domain must already exist, and GoDaddy's
   nameservers for the domain must be set to that zone's NS records (delegation).
   See *One-time: delegate DNS to Route 53* below. AWS credentials with
   Route 53 access (and S3 state access) are used — same creds as the backend.
3. An existing mailbox to forward inbound mail to (e.g. a Gmail address). On
   Mailgun's free plan, forward destinations must be *authorized recipients*.
4. For CI remote state: an **S3 bucket** (state locking is handled natively by
   the S3 backend — no DynamoDB needed), or comment out `terraform/backend.tf`
   to use local state.

## One-time: delegate DNS to Route 53

Terraform expects the hosted zone to already exist (it uses a data source, not
a resource). Create it once and point GoDaddy at it:

```bash
# 1. Create the hosted zone (skip if it already exists).
aws route53 create-hosted-zone \
  --name lokvritfoundation.org \
  --caller-reference "$(date +%s)"

# 2. Read the zone's 4 nameservers.
aws route53 get-hosted-zone --id <ZONE_ID> \
  --query 'DelegationSet.NameServers' --output text
```

Then in the **GoDaddy** dashboard (Domain → *Nameservers* → *Change* → *Enter
my own nameservers*), set the domain's nameservers to those 4 Route 53 values.
Delegation can take up to a few hours to propagate. After the first Terraform
apply you can also read them back with `terraform output route53_name_servers`.

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
# edit terraform.tfvars: domain, aws_region, forward routes

export TF_VAR_mailgun_api_key="key-xxxxxxxxxxxxxxxx"
# AWS credentials for Route 53 + S3 state (standard AWS SDK env vars):
export AWS_ACCESS_KEY_ID="xxxx"
export AWS_SECRET_ACCESS_KEY="xxxx"
export AWS_REGION="ap-south-1"

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
| `AWS_ACCESS_KEY_ID` | AWS credential with Route 53 + S3 state access |
| `AWS_SECRET_ACCESS_KEY` | AWS credential |

**Variables** (*Variables* tab):

| Variable | Example |
|----------|---------|
| `AWS_REGION` | `ap-south-1` |
| `TF_STATE_BUCKET` | `lokvritfoundation-tfstate` |
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
- **The IAM identity needs Route 53 permissions** (`route53:ListHostedZones*`,
  `route53:GetHostedZone`, `route53:ChangeResourceRecordSets`,
  `route53:GetChange`, `route53:ListResourceRecordSets`) in addition to the S3
  state permissions.
- **Provider docs:** [wgebis/mailgun](https://registry.terraform.io/providers/wgebis/mailgun/latest/docs)
  · [hashicorp/aws — route53_record](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53_record)
```
