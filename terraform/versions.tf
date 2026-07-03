# ── Terraform and provider version constraints ─────────────────────────────────
# Pinning versions prevents surprise breaking changes when providers update.
# `required_version` — the minimum Terraform CLI version this code supports
# `required_providers` — declares which providers are needed and where to get them
# `google` provider    — the official HashiCorp Google Cloud provider
# `source`             — registry path: hashicorp maintains this provider
# `version`            — `~> 6.0` means: >= 6.0.0 and < 7.0.0 (minor updates ok)

terraform {
  required_version = ">= 1.7.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

# ── Configure the Google Cloud provider ───────────────────────────────────────
# `project` and `region` are read from variables — never hardcoded here
# This block tells Terraform which GCP account and region to target
provider "google" {
  project = var.project_id
  region  = var.region
}
