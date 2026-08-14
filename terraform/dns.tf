# One A record per Caddyfile vhost, plus (gated, below) discovery.onym.app.
#
# All records are DNS-only (proxied = false). That is an ACME
# constraint, not a preference: Caddy issues Let's Encrypt certificates
# directly, so the challenge — and the wss:// traffic to strfry — must
# reach the droplet, not Cloudflare's edge. The Caddyfile says the same
# thing from its side.
#
# TTL is 120 to byte-match what deploy.sh's cf_upsert_a has always
# written ("auto" would show a diff on the imported records). deploy.sh
# also upserts these same records on every deploy; until that code is
# retired the two writers agree on every field, so neither creates
# drift against the other.

locals {
  # Verified against the live zone 2026-08-14. All five exist and are
  # imported — see imports.tf. discovery.onym.app is NOT in this list:
  # it has its own gated resource below, because its lifecycle starts
  # in another repo.
  stack_hosts = [
    "nostr",      # {$NOSTR_HOST}      — strfry, wss://
    "blossom",    # {$BLOSSOM_HOST}    — media/blob server
    "relayer",    # {$RELAYER_HOST}    — Soroban contract relayer
    "moderation", # {$MODERATION_HOST} — moderation enforcement interface
    "authority",  # {$AUTHORITY_HOST}  — moderation authority
  ]
}

resource "cloudflare_dns_record" "stack" {
  for_each = toset(local.stack_hosts)

  zone_id = var.cloudflare_zone_id
  name    = "${each.key}.${var.cloudflare_zone_name}"
  type    = "A"
  content = digitalocean_droplet.onym_infra.ipv4_address
  ttl     = var.dns_ttl
  proxied = false # ACME + wss must reach the droplet directly (grey cloud)
}

# discovery.onym.app — gated, OFF by default, because CREATING it here
# first would be a trap: nothing in THIS repo serves that name (no
# {$DISCOVERY_HOST} vhost in Caddyfile, not in deploy.sh's HOSTS), so a
# record pointing at the droplet before the vhost exists gives clients
# a Caddy with no matching site and no certificate for the name — a TLS
# handshake failure, not a 404.
#
# The record's lifecycle is BORN in onymchat/onym-discovery: its deploy
# (deploy/onym/ci-deploy.sh, run by deploy.yml) installs the Caddy
# vhost on this droplet, health-checks that the vhost answers, and only
# THEN upserts this A record — deliberately DNS-last. Creating the same
# record from here as well would double-manage it (that script also
# deletes "extra" A records for the name).
#
# Adoption path — flip + import AFTER the first onym-discovery genesis
# deploy has created the record:
#   1. set discovery_deployed = true (tfvars)
#   2. tofu import 'cloudflare_dns_record.discovery[0]' \
#        '<zone_id>/<record_id>'   # record id lookup as in imports.tf
#   3. plan must show no changes — both writers agree on every field
#     (A, droplet IP, TTL 120, grey-cloud), same as the stack records.
# After that, ongoing ownership matches the other five: OpenTofu is the
# system of record, onym-discovery's upsert is a no-op against it.
resource "cloudflare_dns_record" "discovery" {
  count = var.discovery_deployed ? 1 : 0

  zone_id = var.cloudflare_zone_id
  name    = "discovery.${var.cloudflare_zone_name}"
  type    = "A"
  content = digitalocean_droplet.onym_infra.ipv4_address
  ttl     = var.dns_ttl
  proxied = false # same ACME constraint as above
}
