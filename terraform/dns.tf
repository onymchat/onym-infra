# One A record per Caddyfile vhost, plus discovery.onym.app (served by
# the same box: onym-discovery's deploy publishes a static directory to
# this droplet and Caddy vhosts it — see onym-discovery deploy.yml).
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
  # Verified against the live zone 2026-08-14. discovery has no record
  # yet (dig returns nothing), so it is the one genuine CREATE here;
  # the other five are imported — see imports.tf.
  stack_hosts = [
    "nostr",      # {$NOSTR_HOST}      — strfry, wss://
    "blossom",    # {$BLOSSOM_HOST}    — media/blob server
    "relayer",    # {$RELAYER_HOST}    — Soroban contract relayer
    "moderation", # {$MODERATION_HOST} — moderation enforcement interface
    "authority",  # {$AUTHORITY_HOST}  — moderation authority
    "discovery",  # onym-discovery static directory (NEW record)
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
