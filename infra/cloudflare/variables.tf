# =============================================================================
# Variables
# =============================================================================

# -----------------------------------------------------------------------------
# Cloudflare Account
# -----------------------------------------------------------------------------

variable "cloudflare_api_token" {
  description = "Cloudflare API token with Zone and Account permissions"
  type        = string
  sensitive   = true
}

variable "cloudflare_account_id" {
  description = "Cloudflare account ID"
  type        = string
}

variable "cloudflare_zone_id" {
  description = "Cloudflare zone ID for the domain"
  type        = string
}

# -----------------------------------------------------------------------------
# Project
# -----------------------------------------------------------------------------

variable "project" {
  description = "Project name, used for resource naming"
  type        = string
  default     = "opuspopuli"
}

variable "domain_name" {
  description = "Base domain name (e.g., opuspopuli.org)"
  type        = string
}

variable "api_subdomain" {
  description = "Subdomain for the API tunnel (e.g., 'api' → api.opuspopuli.org)"
  type        = string
  default     = "api"
}

variable "app_subdomain" {
  description = "Subdomain for the frontend Pages project (e.g., 'app' → app.opuspopuli.org)"
  type        = string
  default     = "app"
}

# -----------------------------------------------------------------------------
# Feature Toggles (per-environment via tfvars)
# -----------------------------------------------------------------------------

variable "enable_tunnel" {
  description = "Create a Cloudflare Tunnel for API access to the Mac Studio"
  type        = bool
  default     = false
}

variable "enable_frontend" {
  description = "Create DNS records for the Next.js frontend (deployed to Workers via wrangler)"
  type        = bool
  default     = false
}

variable "enable_r2" {
  description = "Create R2 object storage buckets"
  type        = bool
  default     = false
}

# -----------------------------------------------------------------------------
# Tunnel Configuration
# -----------------------------------------------------------------------------

variable "tunnel_api_port" {
  description = "Local port the NestJS API Gateway listens on"
  type        = number
  default     = 8080
}

# -----------------------------------------------------------------------------
# Frontend Configuration
# -----------------------------------------------------------------------------

variable "frontend_worker_subdomain" {
  description = "Workers subdomain for the frontend (used for DNS CNAME if no custom domain)"
  type        = string
  default     = ""
}

# -----------------------------------------------------------------------------
# R2 Configuration
# -----------------------------------------------------------------------------

variable "r2_location_hint" {
  description = "R2 bucket location hint (closest region)"
  type        = string
  default     = "WNAM"
}