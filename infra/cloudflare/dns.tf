# =============================================================================
# Cloudflare DNS Records
# =============================================================================

# -----------------------------------------------------------------------------
# Tunnel CNAME — routes api.* to the tunnel
# -----------------------------------------------------------------------------

resource "cloudflare_record" "tunnel_api" {
  count   = var.enable_tunnel ? 1 : 0
  zone_id = var.cloudflare_zone_id
  name    = local.api_subdomain
  content = "${cloudflare_zero_trust_tunnel_cloudflared.api[0].id}.cfargotunnel.com"
  type    = "CNAME"
  proxied = true
  comment = "Cloudflare Tunnel for ${local.name_prefix} API"
}

# -----------------------------------------------------------------------------
# Frontend CNAME — routes app.* to the Workers-deployed frontend
# -----------------------------------------------------------------------------
# The custom domain is configured via wrangler.toml or Cloudflare dashboard
# when running `pnpm cf:deploy`. This DNS record is created here for
# environments where Terraform manages DNS.

resource "cloudflare_record" "frontend_app" {
  count   = var.enable_frontend && var.frontend_worker_subdomain != "" ? 1 : 0
  zone_id = var.cloudflare_zone_id
  name    = local.app_subdomain
  content = var.frontend_worker_subdomain
  type    = "CNAME"
  proxied = true
  comment = "Cloudflare Workers frontend for ${local.name_prefix}"
}