# =============================================================================
# Cloudflare Tunnel
# =============================================================================
#
# Creates an encrypted outbound-only tunnel from the Mac Studio to Cloudflare's
# edge. No inbound ports, no exposed home IP. The cloudflared daemon runs as a
# Docker container in docker-compose-prod.yml.
#
# Enabled: uat, prod (via enable_tunnel variable)
# =============================================================================

resource "random_id" "tunnel_secret" {
  count       = var.enable_tunnel ? 1 : 0
  byte_length = 32
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "api" {
  count      = var.enable_tunnel ? 1 : 0
  account_id = var.cloudflare_account_id
  name       = local.name_prefix
  secret     = random_id.tunnel_secret[0].b64_std
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "api" {
  count      = var.enable_tunnel ? 1 : 0
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.api[0].id

  config {
    # Route API traffic to the local NestJS gateway
    ingress_rule {
      hostname = local.api_hostname
      service  = "http://localhost:${var.tunnel_api_port}"

      origin_request {
        connect_timeout = "30s"
        no_tls_verify   = true
      }
    }

    # Catch-all: return 404 for unmatched hostnames
    ingress_rule {
      service = "http_status:404"
    }
  }
}