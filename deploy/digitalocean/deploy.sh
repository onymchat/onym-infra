#!/usr/bin/env bash
#
# deploy.sh — Deploy the consolidated onym.app backend to DigitalOcean.
#
# Stack: Caddy (auto-HTTPS) + strfry (Nostr) + blossom + onym-relayer.
# Idempotent: reuses the droplet recorded in .env, re-syncs config, and
# rebuilds containers. Safe to run repeatedly.
#
# Usage:
#   cp .env.example .env && $EDITOR .env          # fill DO_API_KEY, CF_API_TOKEN, ...
#   cp relayer.env.example relayer.env && $EDITOR relayer.env   # fill RELAYER_SECRET_KEY, ...
#   ./deploy/digitalocean/deploy.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_FILE="$REPO_ROOT/.env"
RELAYER_ENV="$REPO_ROOT/relayer.env"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}==> $*${NC}"; }
ok()    { echo -e "${GREEN}==> $*${NC}"; }
warn()  { echo -e "${YELLOW}==> $*${NC}"; }
err()   { echo -e "${RED}==> ERROR: $*${NC}" >&2; }

# ─── Load + validate config ───────────────────────────────────────────

[ -f "$ENV_FILE" ] || { err "Missing $ENV_FILE — copy .env.example and fill it in."; exit 1; }
set -a; source "$ENV_FILE"; set +a

[ -f "$RELAYER_ENV" ] || { err "Missing $RELAYER_ENV — copy relayer.env.example and set RELAYER_SECRET_KEY."; exit 1; }
grep -q '^RELAYER_SECRET_KEY=S' "$RELAYER_ENV" || { err "relayer.env: RELAYER_SECRET_KEY is not set (must start with 'S')."; exit 1; }

: "${DO_API_KEY:?set DO_API_KEY in .env}"
: "${CF_API_TOKEN:?set CF_API_TOKEN in .env}"
: "${DOMAIN:?set DOMAIN in .env}"
: "${NOSTR_HOST:?set NOSTR_HOST in .env}"
: "${BLOSSOM_HOST:?set BLOSSOM_HOST in .env}"
: "${RELAYER_HOST:?set RELAYER_HOST in .env}"
: "${CADDY_EMAIL:?set CADDY_EMAIL in .env}"
DO_REGION="${DO_REGION:-ams3}"
DO_DROPLET_SIZE="${DO_DROPLET_SIZE:-s-1vcpu-2gb}"
SSH_KEY_PATH="${SSH_KEY_PATH:-$HOME/.ssh/id_ed25519}"
# Expand a leading ~ / $HOME that survived from .env.
SSH_KEY_PATH="${SSH_KEY_PATH/#\~/$HOME}"
HOSTS=("$NOSTR_HOST" "$BLOSSOM_HOST" "$RELAYER_HOST")

save_env() {
    # Rewrite DROPLET_ID / DROPLET_IP in place, preserving everything else.
    local tmp; tmp="$(mktemp)"
    grep -vE '^(DROPLET_ID|DROPLET_IP)=' "$ENV_FILE" > "$tmp" || true
    { echo "DROPLET_ID=${DROPLET_ID:-}"; echo "DROPLET_IP=${DROPLET_IP:-}"; } >> "$tmp"
    mv "$tmp" "$ENV_FILE"
}

for c in doctl ssh rsync curl python3 dig; do
    command -v "$c" >/dev/null || { err "missing required command: $c"; exit 1; }
done
[ -f "$SSH_KEY_PATH" ] || { err "SSH key not found at $SSH_KEY_PATH"; exit 1; }

info "Config: domain=$DOMAIN size=$DO_DROPLET_SIZE region=$DO_REGION"
echo "  hosts: ${HOSTS[*]}"

# ─── Authenticate ─────────────────────────────────────────────────────

info "Authenticating with DigitalOcean..."
doctl auth init --access-token "$DO_API_KEY" >/dev/null 2>&1
ok "Authenticated"

info "Ensuring SSH key is registered on DigitalOcean..."
SSH_FP="$(ssh-keygen -lf "${SSH_KEY_PATH}.pub" -E md5 | awk '{print $2}' | sed 's/MD5://')"
if ! doctl compute ssh-key get "$SSH_FP" &>/dev/null; then
    doctl compute ssh-key import "onym-infra-$(basename "$SSH_KEY_PATH")" \
        --public-key-file "${SSH_KEY_PATH}.pub" >/dev/null
    ok "SSH key uploaded"
else
    ok "SSH key already present"
fi

# ─── Create or reuse droplet ──────────────────────────────────────────

if [ -n "${DROPLET_ID:-}" ] && doctl compute droplet get "$DROPLET_ID" &>/dev/null; then
    DROPLET_IP="$(doctl compute droplet get "$DROPLET_ID" --format PublicIPv4 --no-header)"
    ok "Reusing droplet $DROPLET_ID ($DROPLET_IP)"
else
    CLOUD_INIT="$(cat <<'CI'
#!/bin/bash
set -eux
curl -fsSL https://get.docker.com | sh
apt-get install -y docker-compose-plugin git ufw rsync
# Swapfile so the Rust relayer build does not OOM on a 2GB box.
if [ ! -f /swapfile ]; then
  fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048
  chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi
ufw allow 22/tcp && ufw allow 80/tcp && ufw allow 443/tcp && ufw --force enable
touch /tmp/cloud-init-done
CI
)"
    DROPLET_NAME="onym-infra-$(date +%s)"
    info "Creating droplet '$DROPLET_NAME' ($DO_DROPLET_SIZE, $DO_REGION)..."
    DROPLET_ID="$(doctl compute droplet create "$DROPLET_NAME" \
        --image ubuntu-24-04-x64 --size "$DO_DROPLET_SIZE" --region "$DO_REGION" \
        --ssh-keys "$SSH_FP" --user-data "$CLOUD_INIT" --wait \
        --format ID --no-header)"
    DROPLET_IP="$(doctl compute droplet get "$DROPLET_ID" --format PublicIPv4 --no-header)"
    ok "Droplet created: $DROPLET_ID ($DROPLET_IP)"
    save_env

    info "Waiting for cloud-init (docker + swap + firewall)..."
    for i in $(seq 1 60); do
        if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 \
            -i "$SSH_KEY_PATH" "root@$DROPLET_IP" "test -f /tmp/cloud-init-done" 2>/dev/null; then
            ok "Droplet ready"; break
        fi
        [ "$i" -eq 60 ] && { err "cloud-init timed out. SSH in: ssh -i $SSH_KEY_PATH root@$DROPLET_IP"; exit 1; }
        printf '.'; sleep 10
    done; echo
fi
save_env

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 -i "$SSH_KEY_PATH")
ssh_do() { ssh "${SSH_OPTS[@]}" "root@$DROPLET_IP" "$@"; }

# ─── DNS (Cloudflare, DNS-only / grey-cloud) ──────────────────────────

info "Configuring Cloudflare DNS for $DOMAIN (records are DNS-only, not proxied)..."
CF="https://api.cloudflare.com/client/v4"
CF_ZONE_ID="$(curl -s "$CF/zones?name=$DOMAIN" -H "Authorization: Bearer $CF_API_TOKEN" \
    | python3 -c "import sys,json; r=json.load(sys.stdin)['result']; print(r[0]['id'] if r else '')")"
[ -n "$CF_ZONE_ID" ] || { err "Could not find Cloudflare zone for $DOMAIN (check CF_API_TOKEN scope)."; exit 1; }

cf_upsert_a() {
    local name="$1" ip="$2" res existing_id
    res="$(curl -s "$CF/zones/$CF_ZONE_ID/dns_records?type=A&name=$name" \
        -H "Authorization: Bearer $CF_API_TOKEN")"
    existing_id="$(echo "$res" | python3 -c "import sys,json; r=json.load(sys.stdin)['result']; print(r[0]['id'] if r else '')")"
    local body="{\"type\":\"A\",\"name\":\"$name\",\"content\":\"$ip\",\"ttl\":120,\"proxied\":false}"
    if [ -n "$existing_id" ]; then
        curl -s -X PUT "$CF/zones/$CF_ZONE_ID/dns_records/$existing_id" \
            -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" \
            --data "$body" >/dev/null
        ok "  updated $name -> $ip (DNS-only)"
    else
        curl -s -X POST "$CF/zones/$CF_ZONE_ID/dns_records" \
            -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" \
            --data "$body" >/dev/null
        ok "  created $name -> $ip (DNS-only)"
    fi
}
for h in "${HOSTS[@]}"; do cf_upsert_a "$h" "$DROPLET_IP"; done

info "Waiting for DNS to propagate..."
for h in "${HOSTS[@]}"; do
    for i in $(seq 1 30); do
        [ "$(dig +short "$h" @1.1.1.1 | tail -1)" = "$DROPLET_IP" ] && { ok "  $h resolves"; break; }
        [ "$i" -eq 30 ] && { warn "  $h not resolving to $DROPLET_IP yet — Caddy will retry certs once it does."; break; }
        printf '.'; sleep 6
    done
done

# ─── Sync repo + secrets, build, up ───────────────────────────────────

info "Syncing repository to droplet (/opt/onym-infra)..."
ssh_do "mkdir -p /opt/onym-infra"
rsync -az --delete \
    -e "ssh ${SSH_OPTS[*]}" \
    --exclude '.git' --exclude 'relayer/target' --exclude '.env' \
    --exclude 'relayer.env' --exclude '*.log' --exclude '.DS_Store' \
    "$REPO_ROOT/" "root@$DROPLET_IP:/opt/onym-infra/"

info "Writing droplet compose env + relayer secrets..."
# Only the compose-relevant vars go to the droplet — DO/CF tokens stay local.
ssh_do "cat > /opt/onym-infra/.env" <<EOF
DOMAIN=$DOMAIN
NOSTR_HOST=$NOSTR_HOST
BLOSSOM_HOST=$BLOSSOM_HOST
RELAYER_HOST=$RELAYER_HOST
CADDY_EMAIL=$CADDY_EMAIL
EOF
scp "${SSH_OPTS[@]}" "$RELAYER_ENV" "root@$DROPLET_IP:/opt/onym-infra/relayer.env" >/dev/null

info "Building + starting containers (first Rust build takes a few minutes)..."
ssh_do "cd /opt/onym-infra && docker compose build && docker compose up -d"

# ─── Verify ───────────────────────────────────────────────────────────

info "Verifying (certs may take ~30s on first issue)..."
sleep 20
check() {
    local url="$1" label="$2" code
    code="$(curl -o /dev/null -s -w '%{http_code}' --max-time 15 "$url" 2>/dev/null || echo 000)"
    if [ "$code" != "000" ]; then ok "  $label — HTTP $code (TLS OK)"; else warn "  $label — no response yet (cert may still be issuing)"; fi
}
check "https://$RELAYER_HOST/" "relayer"   # expect 401/422 (auth/validation) = up
check "https://$BLOSSOM_HOST/" "blossom"
check "https://$NOSTR_HOST/"   "nostr"     # expect 400/426 on plain GET = up

echo
ok "Done. Droplet $DROPLET_ID @ $DROPLET_IP"
echo "  Nostr:   wss://$NOSTR_HOST"
echo "  Blossom: https://$BLOSSOM_HOST"
echo "  Relayer: https://$RELAYER_HOST"
echo "  Logs:    ssh -i $SSH_KEY_PATH root@$DROPLET_IP 'cd /opt/onym-infra && docker compose logs -f'"
