# =============================================================================
# OPUSPOPULI Cloudflare Infrastructure
# =============================================================================
#
# Zero-AWS infrastructure for Opus Populi. Cloudflare handles the public edge
# (tunnel, DNS, CDN, Pages, R2), Supabase provides managed Postgres, and a
# Mac Studio M4 Max runs all compute locally.
#
# Multi-environment via Terraform workspaces:
#   terraform workspace new uat
#   terraform workspace select uat
#   terraform apply -var-file=environments/uat.tfvars
#
# Environments:
#   dev  — No cloud resources (fully local docker-compose)
#   uat  — Cloudflare Tunnel + Supabase free tier
#   prod — Full stack: Tunnel + Pages + R2 + Supabase Pro
#
# =============================================================================

terraform {
  required_version = ">= 1.0"

  # ---------------------------------------------------------------------------
  # Remote State — Terraform Cloud (free tier)
  # ---------------------------------------------------------------------------
  # Provides remote state storage, locking, encryption, and run history.
  # No AWS resources required.
  #
  # Setup:
  #   1. Create a Terraform Cloud account at https://app.terraform.io
  #   2. Create an organization (e.g., "opuspopuli")
  #   3. Run: terraform login
  #   4. Run: terraform init   (migrates local state to Terraform Cloud)
  #
  # Workspace mapping uses Terraform workspaces (dev, uat, prod) mapped to
  # Terraform Cloud workspaces prefixed with "opuspopuli-".
  # ---------------------------------------------------------------------------
  # Cloud block accepts TF_CLOUD_ORGANIZATION env var as override (each
  # region operator sets it to their own TFC org). Kept un-hardcoded so the
  # central Terraform code is region-portable.
  cloud {
    workspaces {
      tags = ["opuspopuli", "cloudflare"]
    }
  }

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

# -----------------------------------------------------------------------------
# Local values — workspace-aware naming
# -----------------------------------------------------------------------------

locals {
  environment = terraform.workspace
  name_prefix = "${var.project}-${local.environment}"

  # Only prod gets the bare subdomain; other envs get prefixed
  api_subdomain = local.environment == "prod" ? var.api_subdomain : "${local.environment}-${var.api_subdomain}"
  app_subdomain = local.environment == "prod" ? var.app_subdomain : "${local.environment}-${var.app_subdomain}"

  api_hostname = "${local.api_subdomain}.${var.domain_name}"
  app_hostname = "${local.app_subdomain}.${var.domain_name}"
}