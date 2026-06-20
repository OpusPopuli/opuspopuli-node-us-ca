# opuspopuli-node

Everything you need to stand up a production Opus Populi region: Cloudflare infrastructure, Mac Studio bootstrap, Docker Compose for production, backup pipeline, observability.

Use this GitHub template, edit a handful of region-specific values, follow the bootstrap guide. ~5–8 focused hours from sealed-box Mac Studio to public API.

## What this repo is

Each Opus Populi region is operated independently — its own Cloudflare account, its own Mac Studio, its own domain. This repo is the **per-region deployment kit**: everything that belongs to one operator's deployment of one region.

```
opuspopuli (central)              opuspopuli-node-<region> (you)
─────────────────────             ──────────────────────────────
Source code (apps/, packages/)    Cloudflare Terraform
Dockerfiles                       docker-compose-prod.yml
CI builds + publishes:            Backup pipeline
  ghcr.io/opuspopuli/<svc>        Observability configs (prometheus, etc.)
  npm.pkg.github.com/opuspopuli   Mac Studio bootstrap scripts
                                  GitHub Actions for terraform plan/apply
                                  Operator docs
                                  YOUR secrets (GitHub Secrets, never committed)
```

The Mac Studio clones **this repo**, never `opuspopuli` itself. Images come pre-built from `ghcr.io`. npm packages come from `npm.pkg.github.com`. Source code never lands on the Studio.

## Prerequisites (operator does these manually, one-time)

1. **Cloudflare account** with your domain registered or moved to Cloudflare (zone active).
2. **Terraform Cloud organization** — sign up at https://app.terraform.io and create an org.
3. **Resend account** for transactional email.
4. **Mac Studio** (M2 Ultra+ recommended, ≥ 64 GB unified RAM, ≥ 1 TB internal).
5. **UPS** (battery backup — 15+ min runtime under Studio load).
6. **1Password** (or equivalent password manager) to hold the small set of bootstrap secrets that never live in CI or on disk.

## Setup

### 1. Use this template

GitHub → "Use this template" → "Create a new repository" → name it for your region (e.g. `opuspopuli-node-ca`). Clone it locally.

### 2. Configure region-specific values

```bash
cd infra/cloudflare/environments
cp prod.tfvars.example prod.tfvars
# Edit prod.tfvars: set domain_name + project + subdomains for your region
```

Commit and push the edited tfvars (it's NOT in `.gitignore` — it's region config, not secrets).

### 3. Set GitHub Secrets

Repo Settings → Secrets and variables → Actions. Add:

| Secret | Source |
|---|---|
| `CLOUDFLARE_API_TOKEN` | Account-owned API token with: Zone Read, DNS Edit, Tunnel Edit, R2 Storage Edit, Pages Edit (5 scopes) |
| `CLOUDFLARE_ACCOUNT_ID` | Cloudflare dashboard right sidebar |
| `CLOUDFLARE_ZONE_ID` | Your domain → Overview → right sidebar |
| `TF_API_TOKEN` | Terraform Cloud → User Settings → Tokens → Create |
| `TF_CLOUD_ORGANIZATION` | Your TFC organization name |

Enable R2 in the Cloudflare dashboard one time (R2 → Get started → confirm billing). Free tier covers MVP traffic.

### 4. First Terraform apply

Open a PR with your edited `prod.tfvars`. The `cloudflare-infra` workflow runs `terraform plan` and posts the diff as a PR comment. Expect:
- 1 Cloudflare Tunnel
- DNS records for `api.<your-domain>` + `app.<your-domain>`
- 3 R2 buckets (documents, transcripts, scraped)
- 1 Cloudflare Pages project

Review, merge to `main`. The workflow runs `terraform apply`.

### 5. Get the Tunnel token (one time, locally)

The Tunnel token is a sensitive Terraform output. Pull it down once on your laptop and stash it in 1Password:

```bash
cd infra/cloudflare
export TF_CLOUD_ORGANIZATION='<your-tfc-org>'
terraform login
terraform init
terraform workspace select prod
terraform output -raw tunnel_token
# Paste into 1Password under "<your-region>-secrets" → "Tunnel token". Then:
history -c
```

### 6. Resend domain + DKIM

Resend dashboard → Domains → Add Domain → enter your domain. Resend gives you 3 DNS records (SPF, DKIM, DMARC). Add them in Cloudflare DNS, then click Resend → "Verify DNS records." Generate an API key under API Keys with Sending access — save to 1Password.

### 7. R2 backup bucket

Create a separate R2 bucket via the dashboard for nightly DB backups (the Terraform creates the 3 storage buckets but not the backup one):

- Name: `<project>-prod-db-backups`
- 30-day lifecycle rule
- Create a scoped API token (Read+Write, this bucket only) → 1Password

### 8. Generate the pgsodium master key

On your laptop (not the Mac Studio):

```bash
set +o history
head -c 32 /dev/urandom | od -A n -t x1 | tr -d ' \n'; echo
```

Save the 64-hex output to 1Password under the master note AND as a separate item (`<region>-pgsodium-root-key`). This is the single most load-bearing secret — if lost, every Vault entry on the Studio is unrecoverable. The duplicate is your recovery path if the master note ever corrupts.

### 9. Mac Studio bootstrap

At the Studio, clone this repo and run the bootstrap script:

```bash
mkdir -p ~/Development
cd ~/Development
git clone https://github.com/<your-org>/opuspopuli-node-<region>
cd opuspopuli-node-<region>
./scripts/mac-studio-setup.sh
```

The script automates: Homebrew + CLI tools, Docker Desktop install, Tailscale, Ollama (with model pulls), pgsodium key file + LaunchAgent, ghcr.io login.

Full step-by-step (including the manual GUI bits the script can't do): see [`docs/mac-studio-bootstrap.md`](docs/mac-studio-bootstrap.md).

### 10. Pull images and start

```bash
docker compose -f docker-compose-prod.yml pull
docker compose -f docker-compose-prod.yml up -d
```

All ~10 containers (api, users, documents, knowledge, region, 3 workers, db-migrate, cloudflared, plus postgres + redis + observability) pull from ghcr.io and start. ~3–5 min on a warm Studio.

### 11. Verify

From off-LAN (your phone tethered, a friend's laptop):

```bash
curl -i https://api.<your-domain>/health     # HTTP/2 200
```

Browser at `https://app.<your-domain>` → sign up → magic link arrives via Resend → you're live.

## Ongoing operations

- **Update images:** push to `main` in the central `opuspopuli` repo triggers the release workflow → new ghcr.io tags published. On your Studio: `docker compose -f docker-compose-prod.yml pull && docker compose -f docker-compose-prod.yml up -d --remove-orphans`.
- **Pull upstream template updates** (security patches to Terraform, updated bootstrap script, new observability dashboards, etc.):
  ```bash
  # One-time setup, in your node repo's local checkout:
  git remote add upstream https://github.com/OpusPopuli/opuspopuli-node

  # When you want to pull in central updates:
  git fetch upstream
  git checkout -b chore/sync-upstream-$(date +%Y%m%d)
  git merge upstream/main
  # Resolve any conflicts (typically only in files you've region-customized
  # like prod.tfvars, .env.production.example). Push and PR.
  ```
- **Change Cloudflare infra:** edit `infra/cloudflare/*.tf` or `environments/prod.tfvars` on a branch, PR, review the plan comment, merge → apply runs.
- **Rotate the Cloudflare token:** create a new Account API token, update the GitHub Secret, delete the old token. Workflow picks it up on the next run.
- **Rollback to a specific image build:** set `TAG=sha-<commit-sha>` in `.env.production` and re-run `docker compose pull && up -d`.

## Verifying ghcr.io image signatures

Every image at `ghcr.io/opuspopuli/*` is cosign-signed via GitHub Actions OIDC and ships with an SPDX SBOM. Operators should verify periodically:

```bash
brew install cosign
cosign verify ghcr.io/opuspopuli/api:latest \
  --certificate-identity-regexp 'https://github.com/OpusPopuli/opuspopuli/.github/workflows/release.yml@.*' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

A passing verification means the image was built by the official central CI workflow, not tampered.

## Layout

```
.github/workflows/cloudflare-infra.yml   Terraform plan/apply on PR + push
infra/cloudflare/                         Terraform code (region-owned copy)
  main.tf                                 Provider + TFC backend (org via env)
  tunnel.tf, dns.tf, r2.tf, pages.tf      Resource definitions
  variables.tf                            Input variables
  environments/prod.tfvars.example        Copy → prod.tfvars, edit per region
docker-compose-prod.yml                   Production stack (pulls ghcr.io)
docker-compose-backup.yml                 Nightly pg_dump → R2 overlay
backup/                                   Backup container Dockerfile + scripts
observability/                            Prometheus + Grafana + Loki + Tempo configs
supabase/init/pgsodium_getkey_env.sh      Bind-mounted into the db container
scripts/
  mac-studio-setup.sh                     One-shot Studio bootstrap
  start-prod.sh                           Health-check + pull + up
docs/
  mac-studio-bootstrap.md                 Full step-by-step Studio runbook
```

## License

Opus Populi platform code is licensed under AGPL-3.0 + dual commercial. This deployment template inherits the AGPL-3.0 terms — see `LICENSE` (or the central repo's `LICENSE` if not yet copied here).

## Getting help

- Central platform issues: https://github.com/OpusPopuli/opuspopuli/issues
- Operator questions: open an issue in this repo or in your own region's repo.
