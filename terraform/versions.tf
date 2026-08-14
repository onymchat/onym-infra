# OpenTofu, not Terraform — deliberately. OpenTofu is the open-source
# (MPL-2.0) fork under the Linux Foundation; HashiCorp Terraform moved
# to the BUSL. Everything in this directory is written for and CI-run
# with the `tofu` binary. The HCL is currently compatible with both,
# but nothing here promises to stay that way.

terraform {
  # The floor is set by the S3 backend's `use_lockfile` argument
  # (backend.tf): it only exists as of OpenTofu 1.10, and on 1.8/1.9
  # `tofu init` dies with an opaque "Unsupported argument" instead of a
  # clear version message — so the version check must catch it first.
  # (Import blocks need >= 1.5, backend `endpoints` map >= 1.6; both
  # are subsumed.) Written and validated with OpenTofu 1.12.
  required_version = ">= 1.10.0"

  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "2.99.1" # latest stable on registry.opentofu.org, 2026-08-14
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "5.23.0" # v5 API: resource is cloudflare_dns_record, not cloudflare_record
    }
    github = {
      source  = "integrations/github"
      version = "6.13.0"
    }
  }
}

# Auth comes from the environment, never from tfvars or state:
#   DIGITALOCEAN_TOKEN   — DigitalOcean API token (org secret DO_API_KEY in CI)
#   CLOUDFLARE_API_TOKEN — Cloudflare token with DNS:Edit on onym.app (org secret CF_API_TOKEN in CI)
#   GITHUB_TOKEN         — PAT with repo + environments admin on onymchat repos
provider "digitalocean" {}

provider "cloudflare" {}

provider "github" {
  owner = "onymchat"
}
