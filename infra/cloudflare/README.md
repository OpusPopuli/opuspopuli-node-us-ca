# Cloudflare Infrastructure (Terraform)

Terraform configuration for the Opus Populi edge infrastructure. Cloudflare handles public ingress, DNS, CDN, frontend hosting, and object storage — the compute node (Mac Studio or cloud VM) never exposes inbound ports.

## What This Provisions

| Resource | Description | Environments |
|----------|-------------|--------------|
| **Tunnel** | Encrypted outbound-only connection from compute node to Cloudflare edge | uat, prod |
| **DNS** | CNAME records for `api.*` (tunnel) and `app.*` (Workers frontend) | uat, prod |
| **R2 Buckets** | S3-compatible object storage (documents, transcripts, scraped data) | prod |
| **Workers/Pages** | DNS routing for the Next.js frontend deployed via `@opennextjs/cloudflare` | prod |

The dev environment creates no cloud resources — everything runs locally via `docker-compose.yml`.

## Prerequisites

1. **Cloudflare account** (free plan is sufficient)
2. **Domain** added to Cloudflare with nameservers updated at your registrar
3. **API token** with these permissions:
   - Zone > Zone > Read
   - Zone > DNS > Edit
   - Account > Cloudflare Tunnel > Edit
   - Account > R2 > Edit (prod only)
4. **Terraform** >= 1.0 installed
5. **Terraform Cloud account** (free tier — up to 500 managed resources)

### Gather Your IDs

From the Cloudflare dashboard:
- **Account ID**: Overview page (right sidebar)
- **Zone ID**: Domain overview page (right sidebar)

## Terraform Cloud Setup

State is stored remotely in [Terraform Cloud](https://app.terraform.io) with locking, encryption, and run history. No AWS resources required.

```bash
# 1. Create a free Terraform Cloud account at https://app.terraform.io
# 2. Create an organization named "opuspopuli"
# 3. Log in from CLI
terraform login

# 4. Initialize — this migrates local state to Terraform Cloud
cd infra/cloudflare
terraform init
```

In Terraform Cloud, create workspaces tagged with `opuspopuli` and `cloudflare` for each environment (e.g., `opuspopuli-prod`, `opuspopuli-uat`). Set variables in each workspace:

| Variable | Category | Sensitive |
|----------|----------|-----------|
| `cloudflare_api_token` | Terraform | Yes |
| `cloudflare_account_id` | Terraform | No |
| `cloudflare_zone_id` | Terraform | No |
| `domain_name` | Terraform | No |

## Quick Start

```bash
cd infra/cloudflare

# Initialize (connects to Terraform Cloud)
terraform init

# Apply with environment-specific variables
terraform apply -var-file=environments/prod.tfvars
```

> **Tip:** Sensitive variables (API tokens) should be set in Terraform Cloud workspace settings rather than passed on the command line or stored in local files.

## Environments

| Workspace | Cost | What's Created | tfvars |
|-----------|------|----------------|--------|
| `dev` | $0 | Nothing (fully local) | `environments/dev.tfvars` |
| `uat` | ~$0 | Tunnel only (`uat-api.yourdomain.org`) | `environments/uat.tfvars` |
| `prod` | ~$0* | Tunnel + DNS + R2 buckets | `environments/prod.tfvars` |

*Cloudflare free plan covers tunnel, DNS, Workers, and 10 GB R2. Total infrastructure cost is dominated by Supabase ($0-25/mo) and hosting/electricity.

Feature toggles in each tfvars:

```hcl
enable_tunnel   = true   # Cloudflare Tunnel for API access
enable_frontend = true   # DNS record for Workers frontend
enable_r2       = true   # R2 object storage buckets
```

Non-prod environments get prefixed subdomains automatically (e.g., `uat-api.yourdomain.org`).

## Key Outputs

After `terraform apply`, retrieve outputs:

```bash
# Tunnel token (required for docker-compose-prod.yml)
terraform output -raw tunnel_token

# Public API URL
terraform output api_url

# Post-apply instructions
terraform output next_steps
```

Add the `tunnel_token` to your `.env.production` as `TUNNEL_TOKEN`, then start the production stack:

```bash
docker compose -f docker-compose-prod.yml up -d --build
```

## Variables Reference

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `cloudflare_api_token` | Yes | — | API token (sensitive) |
| `cloudflare_account_id` | Yes | — | Cloudflare account ID |
| `cloudflare_zone_id` | Yes | — | Cloudflare zone ID |
| `domain_name` | Yes | — | Base domain (e.g., `opuspopuli.org`) |
| `project` | No | `opuspopuli` | Resource naming prefix |
| `api_subdomain` | No | `api` | API subdomain |
| `app_subdomain` | No | `app` | Frontend subdomain |
| `enable_tunnel` | No | `false` | Create Cloudflare Tunnel |
| `enable_frontend` | No | `false` | Create frontend DNS record |
| `enable_r2` | No | `false` | Create R2 storage buckets |
| `tunnel_api_port` | No | `8080` | Local API Gateway port |
| `r2_location_hint` | No | `WNAM` | R2 bucket region hint |

## File Structure

```
infra/cloudflare/
├── main.tf          # Provider config, Terraform Cloud backend, workspace-aware naming
├── variables.tf     # Input variables
├── outputs.tf       # Tunnel token, URLs, next steps
├── tunnel.tf        # Cloudflare Tunnel + ingress rules
├── dns.tf           # DNS CNAME records
├── r2.tf            # R2 object storage buckets
├── pages.tf         # Workers frontend notes (deployed via wrangler)
└── environments/
    ├── dev.tfvars   # No cloud resources
    ├── uat.tfvars   # Tunnel only
    └── prod.tfvars  # Full stack
```

## Customization

### Using a Different Domain

Set `domain_name` in your tfvars or via `-var`:

```bash
terraform apply -var-file=environments/prod.tfvars -var="domain_name=mycivicdata.org"
```

### Skipping Cloudflare (Cloud VM with Nginx)

If deploying to a cloud VM with a static IP, you don't need Terraform at all. Use Nginx + Let's Encrypt as your reverse proxy. See the [Deployment Guide — Cloud VM Adaptation](../../docs/guides/deployment.md#12-adapting-for-cloud-vms).

### Legacy AWS Infrastructure

The `infra/aws-legacy/` directory contains the previous AWS-based infrastructure (deprecated). It is preserved for reference but is not maintained.

## Related Documentation

- [Deployment Guide](../../docs/guides/deployment.md) — Full step-by-step deployment walkthrough
- [Deployment Architecture](../../docs/architecture/deployment.md) — Topology, networking, cost model
- [Docker Setup](../../docs/guides/docker-setup.md) — Development Docker Compose configuration
