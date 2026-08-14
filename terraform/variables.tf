# Provider credentials are NOT variables: they come from the
# environment only (DIGITALOCEAN_TOKEN, CLOUDFLARE_API_TOKEN,
# GITHUB_TOKEN — see versions.tf). Keeping them out of variables keeps
# them out of tfvars files, out of plan output, and out of state.

variable "droplet_name" {
  description = "Name of the droplet running the compose stack. deploy.sh adopts a droplet by this name, so changing it here without changing deploy.sh forks the deployment."
  type        = string
  default     = "onym-infra"
}

variable "droplet_region" {
  description = "DigitalOcean region slug (deploy.sh default: ams3; verified live 2026-08-14)."
  type        = string
  default     = "ams3"
}

variable "droplet_size" {
  description = "Droplet size slug (deploy.sh default: s-1vcpu-2gb; verified live 2026-08-14)."
  type        = string
  default     = "s-1vcpu-2gb"
}

variable "droplet_image" {
  description = "Image slug the droplet was created from (deploy.sh: ubuntu-24-04-x64). Ignored after import — see lifecycle in droplet.tf."
  type        = string
  default     = "ubuntu-24-04-x64"
}

variable "cloudflare_zone_name" {
  description = "DNS zone the vhosts live in."
  type        = string
  default     = "onym.app"
}

variable "cloudflare_zone_id" {
  description = "Cloudflare zone id for cloudflare_zone_name. Verified live 2026-08-14. Lookup: curl -s 'https://api.cloudflare.com/client/v4/zones?name=onym.app' -H \"Authorization: Bearer $CLOUDFLARE_API_TOKEN\" | jq -r '.result[0].id'"
  type        = string
  default     = "ab7846d23674f404cd0ceffa2f41f1f4"
}

variable "dns_ttl" {
  description = "TTL for the stack's A records. 120 matches what deploy.sh has always written; the import-time plan must show no diff, so do not change this before the first apply."
  type        = number
  default     = 120
}

variable "production_reviewer_user_ids" {
  description = "GitHub user ids required to approve 'production' environment deployments. Default is rinat-enikeev (id verified via `gh api users/rinat-enikeev --jq .id`). Lookup for others: gh api users/<login> --jq .id ; for a team: gh api orgs/onymchat/teams/<slug> --jq .id (use production_reviewer_team_ids)."
  type        = list(number)
  default     = [722716]
}

variable "production_reviewer_team_ids" {
  description = "GitHub team ids required to approve 'production' deployments (alternative/addition to user ids). Lookup: gh api orgs/onymchat/teams/employees --jq .id"
  type        = list(number)
  default     = []
}

variable "manage_branch_protection" {
  description = "Off by default: whether this configuration also manages branch protection for main on onym-infra itself. Turn on only once the team wants IaC owning that knob."
  type        = bool
  default     = false
}
