# =============================================================================
# Outputs
# =============================================================================

output "environment" {
  description = "Current Terraform workspace/environment"
  value       = local.environment
}

# -----------------------------------------------------------------------------
# Tunnel
# -----------------------------------------------------------------------------

output "tunnel_id" {
  description = "Cloudflare Tunnel ID"
  value       = var.enable_tunnel ? cloudflare_zero_trust_tunnel_cloudflared.api[0].id : null
}

output "tunnel_token" {
  description = "Tunnel token for cloudflared daemon (use in docker-compose TUNNEL_TOKEN env var)"
  value       = var.enable_tunnel ? cloudflare_zero_trust_tunnel_cloudflared.api[0].tunnel_token : null
  sensitive   = true
}

output "tunnel_cname" {
  description = "Tunnel CNAME target"
  value       = var.enable_tunnel ? "${cloudflare_zero_trust_tunnel_cloudflared.api[0].id}.cfargotunnel.com" : null
}

output "api_url" {
  description = "Public API URL"
  value       = var.enable_tunnel ? "https://${local.api_hostname}" : null
}

# -----------------------------------------------------------------------------
# Frontend (Workers)
# -----------------------------------------------------------------------------

output "app_url" {
  description = "Public frontend URL (custom domain)"
  value       = var.enable_frontend ? "https://${local.app_hostname}" : null
}

# -----------------------------------------------------------------------------
# R2
# -----------------------------------------------------------------------------

output "r2_documents_bucket" {
  description = "R2 documents bucket name"
  value       = var.enable_r2 ? cloudflare_r2_bucket.documents[0].name : null
}

output "r2_transcripts_bucket" {
  description = "R2 transcripts bucket name"
  value       = var.enable_r2 ? cloudflare_r2_bucket.transcripts[0].name : null
}

output "r2_scraped_bucket" {
  description = "R2 scraped data bucket name"
  value       = var.enable_r2 ? cloudflare_r2_bucket.scraped[0].name : null
}

# -----------------------------------------------------------------------------
# Quick-start
# -----------------------------------------------------------------------------

output "next_steps" {
  description = "Post-apply instructions"
  value       = var.enable_tunnel ? "Tunnel '${local.name_prefix}' created. Run: terraform output -raw tunnel_token | pbcopy, then add TUNNEL_TOKEN to .env.production and start docker-compose-prod.yml. Verify: curl https://${local.api_hostname}/health" : "No cloud resources for this environment. Use docker-compose.yml for local dev."
}