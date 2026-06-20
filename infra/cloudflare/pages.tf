# =============================================================================
# Cloudflare Workers — Next.js Frontend (via @opennextjs/cloudflare)
# =============================================================================
#
# The frontend is deployed to Cloudflare Workers using @opennextjs/cloudflare.
# Deployment is handled via CLI/CI: `pnpm cf:deploy` (runs `wrangler deploy`).
#
# Custom domain routing is configured in apps/frontend/wrangler.toml.
# The DNS record for the app subdomain is managed in dns.tf.
#
# No Terraform-managed Worker resources are needed — the Worker script
# is deployed by wrangler, and custom domains are set via the dashboard
# or wrangler.toml routes.
#
# Enabled: prod only (via enable_frontend variable)
# =============================================================================

# The frontend Worker is deployed via `opennextjs-cloudflare deploy` / `wrangler deploy`.
# Custom domain (app.opuspopuli.org) is configured via wrangler.toml or Cloudflare dashboard.
# See: apps/frontend/wrangler.toml
