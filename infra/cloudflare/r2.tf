# =============================================================================
# Cloudflare R2 — Object Storage
# =============================================================================
#
# S3-compatible object storage with zero egress fees.
# Used for documents, transcripts, and scraped data.
#
# Enabled: prod only (via enable_r2 variable)
# Dev/UAT use Supabase Storage instead.
# =============================================================================

resource "cloudflare_r2_bucket" "documents" {
  count         = var.enable_r2 ? 1 : 0
  account_id    = var.cloudflare_account_id
  name          = "${var.project}-documents-${local.environment}"
  location      = var.r2_location_hint
}

resource "cloudflare_r2_bucket" "transcripts" {
  count         = var.enable_r2 ? 1 : 0
  account_id    = var.cloudflare_account_id
  name          = "${var.project}-transcripts-${local.environment}"
  location      = var.r2_location_hint
}

resource "cloudflare_r2_bucket" "scraped" {
  count         = var.enable_r2 ? 1 : 0
  account_id    = var.cloudflare_account_id
  name          = "${var.project}-scraped-${local.environment}"
  location      = var.r2_location_hint
}