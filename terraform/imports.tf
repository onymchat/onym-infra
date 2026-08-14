# Import blocks for everything that already exists. All ids below were
# resolved READ-ONLY from the live account/zone on 2026-08-14 — none
# are placeholders. Each block keeps its lookup command anyway, so a
# future re-bootstrap (or a second deployment of this stack) can
# re-resolve them.
#
# These blocks are declarative: the first `tofu plan` shows them as
# imports, the first `tofu apply` performs them, and afterwards the
# blocks are inert (safe to keep, fine to delete).
#
# NOT imported, because verified absent on 2026-08-14 (they are the
# only CREATEs the first plan should show):
#   - digitalocean_firewall.onym_infra        (no firewall attached today)
#   - cloudflare_dns_record.stack["discovery"] (no A record yet)
#   - github_repository_environment.production[*] (neither repo has the
#     environment: `gh api repos/onymchat/<repo>/environments` -> total_count 0.
#     If one appears before first apply, import it with id
#     "<repo>:production", e.g.:
#       tofu import 'github_repository_environment.production["onym-discovery"]' 'onym-discovery:production')

# ─── Droplet ────────────────────────────────────────────────────────────
# Lookup: doctl compute droplet list onym-infra --format ID --no-header
import {
  to = digitalocean_droplet.onym_infra
  id = "585464063"
}

# ─── Cloudflare A records ──────────────────────────────────────────────
# Import id format (cloudflare provider v5): <zone_id>/<record_id>
# Zone id lookup:
#   curl -s 'https://api.cloudflare.com/client/v4/zones?name=onym.app' \
#     -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" | jq -r '.result[0].id'
# Record id lookup (per host):
#   curl -s "https://api.cloudflare.com/client/v4/zones/ab7846d23674f404cd0ceffa2f41f1f4/dns_records?type=A&name=<host>.onym.app" \
#     -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" | jq -r '.result[0].id'

import {
  to = cloudflare_dns_record.stack["nostr"]
  id = "ab7846d23674f404cd0ceffa2f41f1f4/455b29cc9967bf591af5716262e0353c"
}

import {
  to = cloudflare_dns_record.stack["blossom"]
  id = "ab7846d23674f404cd0ceffa2f41f1f4/fdb985f825b2964c2129d60da13c072f"
}

import {
  to = cloudflare_dns_record.stack["relayer"]
  id = "ab7846d23674f404cd0ceffa2f41f1f4/4187624fe47f568a8bf9e05853876d92"
}

import {
  to = cloudflare_dns_record.stack["moderation"]
  id = "ab7846d23674f404cd0ceffa2f41f1f4/395058d02cf55bd5d11d8d9adf64e785"
}

import {
  to = cloudflare_dns_record.stack["authority"]
  id = "ab7846d23674f404cd0ceffa2f41f1f4/840300919a161c6427782554b80f4cdf"
}
