#!/usr/bin/env bash
#
# deploy.sh — Deploy the consolidated onym.app backend to DigitalOcean.
#
# Stack: Caddy (auto-HTTPS) + strfry (Nostr) + blossom + onym-relayer +
# the three onym-moderation services (Apple + Android enforcement
# interfaces, authority).
# Idempotent: reuses the droplet recorded in .env, re-syncs config, and
# rebuilds containers. Safe to run repeatedly.
#
# Images come from a container registry when DOCR_NAME is set, and are
# built on the droplet when it is not. See "Container images" below.
#
# Usage:
#   cp .env.example .env && $EDITOR .env          # fill DO_API_KEY, CF_API_TOKEN, ...
#   cp relayer.env.example relayer.env && $EDITOR relayer.env   # fill RELAYER_SECRET_KEY, ...
#   cp moderation.env.example moderation.env && $EDITOR moderation.env  # DeviceCheck key, seed, ...
#   cp moderation-android.env.example moderation-android.env && $EDITOR moderation-android.env  # Play SA key, seed, ...
#   cp authority.env.example authority.env && $EDITOR authority.env     # signing seed, tokens, ...
#   cp backup.env.example backup.env && $EDITOR backup.env               # BACKUP_SIGNING_SEED
#   ./deploy/digitalocean/deploy.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_FILE="$REPO_ROOT/.env"
RELAYER_ENV="$REPO_ROOT/relayer.env"
MODERATION_ENV="$REPO_ROOT/moderation.env"
MODERATION_ANDROID_ENV="$REPO_ROOT/moderation-android.env"
AUTHORITY_ENV="$REPO_ROOT/authority.env"
BACKUP_ENV="$REPO_ROOT/backup.env"

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

# Both moderation services refuse to boot without their Ed25519 seed,
# and a container that dies on start is a worse way to learn that than
# a message here. Check the shape now: 32 bytes, hex.
[ -f "$MODERATION_ENV" ] || { err "Missing $MODERATION_ENV — copy moderation.env.example and fill it in."; exit 1; }
grep -qE '^MODERATION_INTERFACE_SIGNING_SEED=[0-9a-fA-F]{64}$' "$MODERATION_ENV" \
    || { err "moderation.env: MODERATION_INTERFACE_SIGNING_SEED must be 64 hex chars (openssl rand -hex 32)."; exit 1; }
# The backup operator refuses to boot without its seed too — and this
# one is worse to get wrong than the moderation seeds. A client that
# consents to this operator pins the public key derived from it, so
# regenerating it makes the operator a different operator to everyone
# already enrolled, with no route that repairs it.
[ -f "$BACKUP_ENV" ] || { err "Missing $BACKUP_ENV — copy backup.env.example and set BACKUP_SIGNING_SEED."; exit 1; }
grep -qE '^BACKUP_SIGNING_SEED=[0-9a-fA-F]{64}$' "$BACKUP_ENV" \
    || { err "backup.env: BACKUP_SIGNING_SEED must be 64 hex chars (openssl rand -hex 32)."; exit 1; }

[ -f "$MODERATION_ANDROID_ENV" ] || { err "Missing $MODERATION_ANDROID_ENV — copy moderation-android.env.example and fill it in."; exit 1; }
grep -qE '^MODERATION_INTERFACE_SIGNING_SEED=[0-9a-fA-F]{64}$' "$MODERATION_ANDROID_ENV" \
    || { err "moderation-android.env: MODERATION_INTERFACE_SIGNING_SEED must be 64 hex chars (openssl rand -hex 32)."; exit 1; }
# The two interfaces are different components with different
# countersigning identities; a shared seed would make their
# countersignatures interchangeable, which the per-component key
# scoping exists to prevent.
if [ "$(grep -E '^MODERATION_INTERFACE_SIGNING_SEED=' "$MODERATION_ENV")" = "$(grep -E '^MODERATION_INTERFACE_SIGNING_SEED=' "$MODERATION_ANDROID_ENV")" ]; then
    err "moderation.env and moderation-android.env share one MODERATION_INTERFACE_SIGNING_SEED —"
    err "the Apple and Android interfaces must countersign with different keys."
    exit 1
fi
# An empty token here fails SILENTLY at the worst spot: the deploy
# goes green, and every verdict the authority delivers to the Android
# interface is refused at its /v1/verdicts. Same posture as the
# AUTHORITY_ADMIN_TOKEN check below.
grep -qE '^MODERATION_AUTHORITY_TOKEN=.+$' "$MODERATION_ANDROID_ENV" \
    || { err "moderation-android.env: MODERATION_AUTHORITY_TOKEN is required — without it the"; \
         err "Android verdict endpoint refuses everything and delivery dies silently."; exit 1; }
# The SA key without cert digests is a silently-degraded deployment:
# play_configured() requires both, so the gate keeps answering
# checkRequired while the operator believes enforcement is on.
if grep -qE '^MODERATION_PLAY_SA_KEY_JSON=.+$' "$MODERATION_ANDROID_ENV" \
    && [ -z "${MODERATION_PLAY_CERT_SHA256_DIGESTS:-}" ]; then
    err "moderation-android.env sets MODERATION_PLAY_SA_KEY_JSON but"
    err "MODERATION_PLAY_CERT_SHA256_DIGESTS is empty in .env — the service would stay"
    err "degraded (checkRequired for everyone) despite the key. Set the digest(s),"
    err "base64url-nopad (see .env.example for the conversion)."
    exit 1
fi
[ -f "$AUTHORITY_ENV" ] || { err "Missing $AUTHORITY_ENV — copy authority.env.example and fill it in."; exit 1; }
grep -qE '^AUTHORITY_SIGNING_SEED=[0-9a-fA-F]{64}$' "$AUTHORITY_ENV" \
    || { err "authority.env: AUTHORITY_SIGNING_SEED must be 64 hex chars (openssl rand -hex 32)."; exit 1; }
# Autonomous triage is off in this stack. Current onym-moderation main
# refuses to boot with no decider, and the admin panel is also the only
# implemented human appeal route, so an empty token is a deployment
# error rather than a service health surprise.
grep -qE '^AUTHORITY_ADMIN_TOKEN=.+$' "$AUTHORITY_ENV" \
    || { err "authority.env: AUTHORITY_ADMIN_TOKEN is required while autonomous triage is off."; exit 1; }
# Without an Android route, verdicts for onym:component:onym-android
# mandates fall through to the DEFAULT route and land on the Apple
# interface, which never countersigned them (no_mandate, retired after
# a few refusals). The trailing `|.+` also refuses a route whose
# bearer token is empty — that parses upstream but delivers nothing.
grep -qE '^AUTHORITY_INTERFACE_ROUTES=.*onym:component:onym-android=https://[^|,]+\|.+$' "$AUTHORITY_ENV" \
    || { err "authority.env: AUTHORITY_INTERFACE_ROUTES must carry an entry"; \
         err "  onym:component:onym-android=https://<android-host>|<token>"; \
         err "or Android verdicts are delivered to the Apple interface. See authority.env.example."; exit 1; }

# The reference manifest and policy documents ship in the submodule.
# Deployment cannot safely continue without them: the authority would
# fail to boot or publish terms nobody can read.
[ -f "$REPO_ROOT/moderation/authority/manifest/manifest.json" ] \
    || { err "moderation/authority/manifest/manifest.json is missing (submodule not checked out?)."; exit 1; }
[ -d "$REPO_ROOT/moderation/authority/published" ] \
    || { err "moderation/authority/published/ is missing (submodule not checked out?)."; exit 1; }

: "${DO_API_KEY:?set DO_API_KEY in .env}"
: "${CF_API_TOKEN:?set CF_API_TOKEN in .env}"
: "${DOMAIN:?set DOMAIN in .env}"
: "${NOSTR_HOST:?set NOSTR_HOST in .env}"
: "${BLOSSOM_HOST:?set BLOSSOM_HOST in .env}"
: "${RELAYER_HOST:?set RELAYER_HOST in .env}"
: "${MODERATION_HOST:?set MODERATION_HOST in .env}"
: "${MODERATION_ANDROID_HOST:?set MODERATION_ANDROID_HOST in .env}"
: "${AUTHORITY_HOST:?set AUTHORITY_HOST in .env}"
: "${DISCOVERY_HOST:?set DISCOVERY_HOST in .env}"
: "${BACKUP_HOST:?set BACKUP_HOST in .env}"
: "${MODERATION_ENFORCE_SIGNATURES:?set MODERATION_ENFORCE_SIGNATURES in .env (normally true)}"
: "${CADDY_EMAIL:?set CADDY_EMAIL in .env}"
[[ "$AUTHORITY_HOST" =~ ^[A-Za-z0-9.-]+$ ]] \
    || { err "AUTHORITY_HOST must be a hostname without a scheme or path."; exit 1; }
[[ "$MODERATION_HOST" =~ ^[A-Za-z0-9.-]+$ ]] \
    || { err "MODERATION_HOST must be a hostname without a scheme or path."; exit 1; }
[[ "$MODERATION_ANDROID_HOST" =~ ^[A-Za-z0-9.-]+$ ]] \
    || { err "MODERATION_ANDROID_HOST must be a hostname without a scheme or path."; exit 1; }
# The operator builds BACKUP_PUBLIC_URL from this and publishes it in a
# signed manifest that clients bind to, so a scheme or path here would
# be advertised to every enrolled device.
[[ "$BACKUP_HOST" =~ ^[A-Za-z0-9.-]+$ ]] \
    || { err "BACKUP_HOST must be a hostname without a scheme or path."; exit 1; }
DO_REGION="${DO_REGION:-ams3}"
# Eight containers, and strfry alone wants CPU for secp256k1 verification
# on every ingest plus per-subscription matching of every new event. The
# old s-1vcpu-2gb was already at its ceiling — cloud-init below adds a
# 2G swapfile specifically because the relayer build OOMed on it.
#
# NOTE: this only applies to a droplet being CREATED. The reuse branch
# below adopts an existing droplet by name and never resizes it, so
# changing this does NOT grow the running box. Growing the live one is
# a resize (same droplet ID, same public IP — the Cloudflare records
# below stay valid — same volumes, data intact), but it needs a
# power-off, so it stays deliberately manual:
#   doctl compute droplet-action power-off <ID> --wait
#   doctl compute droplet-action resize <ID> --size s-2vcpu-4gb --wait
#   doctl compute droplet-action power-on <ID> --wait
#
# Deliberately WITHOUT --resize-disk: a CPU/RAM-only resize is
# reversible, a disk resize is permanent and locks out ever scaling
# back down. Disk is not the constraint here (~450 MB/yr against the
# existing 50 GB — see README "Capacity"), so the 50 GB disk carries
# over unchanged and the option to downsize is worth more than it.
DO_DROPLET_SIZE="${DO_DROPLET_SIZE:-s-2vcpu-4gb}"
SSH_KEY_PATH="${SSH_KEY_PATH:-$HOME/.ssh/id_ed25519}"
# Expand a leading ~ / $HOME that survived from .env.
SSH_KEY_PATH="${SSH_KEY_PATH/#\~/$HOME}"
# This array drives both the Cloudflare A records and the post-deploy
# health checks, so a host that is missing here silently gets neither.
HOSTS=("$NOSTR_HOST" "$BLOSSOM_HOST" "$RELAYER_HOST" "$MODERATION_HOST" "$MODERATION_ANDROID_HOST" "$AUTHORITY_HOST" "$DISCOVERY_HOST" "$BACKUP_HOST")

save_env() {
    # Rewrite only the droplet identity this run resolved, preserving
    # every configured value and its explanatory comments in place.
    local tmp; tmp="$(mktemp)"
    grep -vE '^(DROPLET_ID|DROPLET_IP)=' "$ENV_FILE" > "$tmp" || true
    {
        echo "DROPLET_ID=${DROPLET_ID:-}"
        echo "DROPLET_IP=${DROPLET_IP:-}"
    } >> "$tmp"
    mv "$tmp" "$ENV_FILE"
}

for c in doctl ssh rsync curl python3 dig shasum; do
    command -v "$c" >/dev/null || { err "missing required command: $c"; exit 1; }
done
# Only registry mode builds anything locally; legacy mode still builds
# on the droplet and needs no local Docker at all.
if [ -n "${DOCR_NAME:-}" ]; then
    command -v docker >/dev/null || { err "DOCR_NAME is set but docker is not installed."; exit 1; }
    docker buildx version >/dev/null 2>&1 \
        || { err "DOCR_NAME is set but 'docker buildx' is unavailable."; exit 1; }
fi
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

# ─── Container images ─────────────────────────────────────────────────
#
# Two modes, chosen by DOCR_NAME:
#
#   set    Images are built here (or found already built) and PULLED on
#          the droplet. Tags are the submodule commit, so an unchanged
#          submodule skips the build entirely — the common case for a
#          config-only deploy — and the droplet never compiles Rust.
#
#   unset  Legacy: sources are rsynced and built in place. It works, and
#          it is also why this deployment cannot be more than one box —
#          five Rust builds on a 2GB droplet, serialized so they do not
#          OOM. Nothing here is a second machine until images are built
#          once and pulled many times.
#
# The registry authenticates with the DO_API_KEY this script already
# requires, so turning it on adds no new secret — only a one-time
# `doctl registry create`.
#
# This runs before the droplet exists on purpose: a build that fails
# should fail before any infrastructure is created or mutated.

DOCR_NAME="${DOCR_NAME:-}"
DOCR_HOST="registry.digitalocean.com"
# Refreshed on every deploy, so an abandoned box loses its pull
# credential by going stale rather than by anyone remembering to revoke.
DOCR_CRED_TTL="${DOCR_CRED_TTL:-2592000}"   # 30 days
BUILDX_BUILDER="onym-infra"
RELAYER_IMAGE=""; MODERATION_IMAGE=""; MODERATION_ANDROID_IMAGE=""; AUTHORITY_IMAGE=""; BACKUP_IMAGE=""

# <image-name> <build-context> -> a registry ref tagged with the commit
# of the submodule that context lives in.
image_ref() {
    local name="$1" context="$2" sha suffix=""
    sha="$(git -C "$REPO_ROOT/$context" rev-parse --short=12 HEAD 2>/dev/null)" \
        || { err "$context is not a git checkout — is the submodule initialized?"; exit 1; }
    # A dirty context gets a -dirty tag and is always rebuilt: the SHA
    # has stopped describing what would be built, and quietly shipping
    # the last clean image is the wrong way to lose someone's edit.
    # Scoped with `-- .` so uncommitted work in apple/ does not force a
    # rebuild of authority/, which shares its submodule.
    [ -z "$(git -C "$REPO_ROOT/$context" status --porcelain -- . 2>/dev/null)" ] || suffix="-dirty"
    printf '%s/%s/%s:%s%s' "$DOCR_HOST" "$DOCR_NAME" "$name" "$sha" "$suffix"
}

ensure_image() {
    local ref="$1" context="$2"
    # The whole context is uploaded to the builder, and a Rust context
    # that has been built in carries a target/ tree far larger than the
    # source. Building on the droplet never hit this — rsync excluded
    # target/ explicitly — so the exclusion has to exist in the context
    # itself now. relayer/ ships one; the two moderation contexts do
    # not (onym-moderation follow-up). Fresh CI checkouts are
    # unaffected, so this warns rather than blocks.
    if [ ! -f "$REPO_ROOT/$context/.dockerignore" ] && [ -d "$REPO_ROOT/$context/target" ]; then
        warn "  $context has a target/ tree and no .dockerignore — the build"
        warn "  context will include it. Add .dockerignore upstream (see relayer/)."
    fi
    if [[ "$ref" != *-dirty ]] && docker manifest inspect "$ref" >/dev/null 2>&1; then
        ok "  $ref (already built)"
        return
    fi
    info "  building $ref"
    # --platform is not optional. The droplet is amd64; a developer on
    # Apple silicon would otherwise push an arm64 image that deploys
    # cleanly and then dies with exec format error at the far end.
    # The docker-container driver is what makes cross-building and
    # --push work the same way on a laptop and on a CI runner.
    docker buildx build --builder "$BUILDX_BUILDER" \
        --platform linux/amd64 --push -t "$ref" "$REPO_ROOT/$context"
}

if [ -n "$DOCR_NAME" ]; then
    info "Container images: $DOCR_HOST/$DOCR_NAME"
    # DigitalOcean allows exactly one registry per account, so this is a
    # name check rather than a lookup — and a mismatch means DOCR_NAME
    # is wrong, not that a registry is missing.
    if ! doctl registry get >/dev/null 2>&1; then
        err "This DigitalOcean account has no container registry."
        err "It is a billed resource, so this script will not create one for you:"
        err "  doctl registry create $DOCR_NAME --region $DO_REGION"
        exit 1
    fi
    # Only a positively-read, differing name is an error. An unreadable
    # one (doctl changed its columns) falls through to the login, which
    # fails loudly on its own rather than being blocked here by a
    # cosmetic parse.
    REGISTRY_NAME="$(doctl registry get --format Name --no-header 2>/dev/null | head -1 | tr -d '[:space:]')"
    if [ -n "$REGISTRY_NAME" ] && [ "$REGISTRY_NAME" != "$DOCR_NAME" ]; then
        err "DOCR_NAME is '$DOCR_NAME' but this account's registry is '$REGISTRY_NAME'."
        exit 1
    fi
    doctl registry login >/dev/null
    docker buildx inspect "$BUILDX_BUILDER" >/dev/null 2>&1 \
        || docker buildx create --name "$BUILDX_BUILDER" --driver docker-container >/dev/null

    RELAYER_IMAGE="$(image_ref relayer relayer)"
    MODERATION_IMAGE="$(image_ref moderation-apple moderation/apple)"
    MODERATION_ANDROID_IMAGE="$(image_ref moderation-android moderation/android)"
    AUTHORITY_IMAGE="$(image_ref moderation-authority moderation/authority)"
    BACKUP_IMAGE="$(image_ref backup backup)"
    ensure_image "$RELAYER_IMAGE"            relayer
    ensure_image "$MODERATION_IMAGE"         moderation/apple
    ensure_image "$MODERATION_ANDROID_IMAGE" moderation/android
    ensure_image "$AUTHORITY_IMAGE"          moderation/authority
    ensure_image "$BACKUP_IMAGE"             backup
    ok "Images ready"
else
    warn "DOCR_NAME unset — building on the droplet. See README: Container images."
fi

# ─── Create or reuse droplet ──────────────────────────────────────────

DROPLET_NAME="${DROPLET_NAME:-onym-infra}"
# Idempotent resolution: prefer an explicit DROPLET_ID, otherwise adopt
# an existing droplet with the stable name. This makes repeat runs —
# local OR CI (where .env is rebuilt each time and DROPLET_ID may be
# unset) — update the same box instead of spawning a new one.
if [ -z "${DROPLET_ID:-}" ] || ! doctl compute droplet get "$DROPLET_ID" &>/dev/null; then
    DROPLET_ID="$(doctl compute droplet list "$DROPLET_NAME" --format ID --no-header 2>/dev/null | head -1)"
fi

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
    --exclude '.git' --exclude 'relayer/target' \
    --exclude 'moderation/apple/target' --exclude 'moderation/authority/target' \
    --exclude 'moderation/android/target' \
    --exclude 'runtime/' \
    --exclude '.env' \
    --exclude 'relayer.env' --exclude 'moderation.env' --exclude 'moderation-android.env' \
    --exclude 'authority.env' \
    --exclude '*.log' --exclude '.DS_Store' \
    "$REPO_ROOT/" "root@$DROPLET_IP:/opt/onym-infra/"

info "Writing droplet compose env + service secrets..."
# Only the compose-relevant vars go to the droplet — DO/CF tokens stay
# local. The moderation settings here are the non-secret ones: which
# DeviceCheck environment to talk to, whether verdict signatures are
# enforced, and the interface's public countersigning key. Their
# secrets travel separately, in the env files below.
ssh_do "cat > /opt/onym-infra/.env" <<EOF
DOMAIN=$DOMAIN
NOSTR_HOST=$NOSTR_HOST
BLOSSOM_HOST=$BLOSSOM_HOST
RELAYER_HOST=$RELAYER_HOST
MODERATION_HOST=$MODERATION_HOST
MODERATION_ANDROID_HOST=$MODERATION_ANDROID_HOST
AUTHORITY_HOST=$AUTHORITY_HOST
DISCOVERY_HOST=$DISCOVERY_HOST
BACKUP_HOST=$BACKUP_HOST
BACKUP_COMPONENT_ID=${BACKUP_COMPONENT_ID:-onym:component:onym-backup}
BACKUP_MAX_SNAPSHOT_BYTES=${BACKUP_MAX_SNAPSHOT_BYTES:-268435456}
BACKUP_MAX_SNAPSHOTS=${BACKUP_MAX_SNAPSHOTS:-2}
MODERATION_DEVICECHECK_ENV=${MODERATION_DEVICECHECK_ENV:-production}
MODERATION_ENFORCE_SIGNATURES=$MODERATION_ENFORCE_SIGNATURES
MODERATION_INTERFACE_KEY_EPOCHS=${MODERATION_INTERFACE_KEY_EPOCHS:-}
MODERATION_ANDROID_INTERFACE_KEY_EPOCHS=${MODERATION_ANDROID_INTERFACE_KEY_EPOCHS:-}
MODERATION_ANDROID_INTERFACE_COMPONENT_ID=${MODERATION_ANDROID_INTERFACE_COMPONENT_ID:-onym:component:onym-android}
MODERATION_PLAY_PACKAGE_NAME=${MODERATION_PLAY_PACKAGE_NAME:-}
MODERATION_PLAY_CERT_SHA256_DIGESTS=${MODERATION_PLAY_CERT_SHA256_DIGESTS:-}
MODERATION_REQUIRE_RECALL=${MODERATION_REQUIRE_RECALL:-true}
AUTHORITY_INTERFACE_KEY=${AUTHORITY_INTERFACE_KEY:-}
AUTHORITY_INTERFACE_KEYS_BY_COMPONENT=${AUTHORITY_INTERFACE_KEYS_BY_COMPONENT:-}
AUTHORITY_TRIAGE_MODE=${AUTHORITY_TRIAGE_MODE:-off}
AUTHORITY_QA_ALLOW_EARLY_BAN=${AUTHORITY_QA_ALLOW_EARLY_BAN:-false}
AUTHORITY_MANIFEST_NAME=${AUTHORITY_MANIFEST_NAME:-}
CADDY_EMAIL=$CADDY_EMAIL
# Empty in legacy mode; compose then falls back to the :local tags that
# a droplet-side build produces.
RELAYER_IMAGE=$RELAYER_IMAGE
MODERATION_IMAGE=$MODERATION_IMAGE
MODERATION_ANDROID_IMAGE=$MODERATION_ANDROID_IMAGE
AUTHORITY_IMAGE=$AUTHORITY_IMAGE
BACKUP_IMAGE=$BACKUP_IMAGE
EOF
scp "${SSH_OPTS[@]}" "$RELAYER_ENV" "root@$DROPLET_IP:/opt/onym-infra/relayer.env" >/dev/null
scp "${SSH_OPTS[@]}" "$MODERATION_ENV" "root@$DROPLET_IP:/opt/onym-infra/moderation.env" >/dev/null
scp "${SSH_OPTS[@]}" "$MODERATION_ANDROID_ENV" "root@$DROPLET_IP:/opt/onym-infra/moderation-android.env" >/dev/null
scp "${SSH_OPTS[@]}" "$AUTHORITY_ENV" "root@$DROPLET_IP:/opt/onym-infra/authority.env" >/dev/null
scp "${SSH_OPTS[@]}" "$BACKUP_ENV" "root@$DROPLET_IP:/opt/onym-infra/backup.env" >/dev/null

ssh_do "mkdir -p /opt/onym-infra/runtime/authority-manifest"

# The discovery web root lives OUTSIDE /opt/onym-infra on purpose: its
# contents are published by the onym-discovery repo's Deploy workflow,
# and the rsync --delete above must never sweep a published, signed
# chain away. Created here so Caddy's bind mount serves clean 404s (a
# valid degraded state) rather than depending on Docker to invent the
# directory. Nothing in this repo ever writes INTO it.
ssh_do "mkdir -p /var/www/discovery"

# The backup operator's blob root must be a real mount, and this
# refuses to deploy if it is not.
#
# Sealed snapshots are the only thing on this box measured in
# gigabytes. On the root filesystem they would share 50 GB with
# strfry's event database and both moderation stores — and a full disk
# there is not "backup is unavailable", it is the authority unable to
# record a verdict and the relay unable to accept an event. That is the
# same blast-radius argument the compose memory limits make, applied to
# the one resource that had no limit.
#
# Deliberately NOT provisioned here. Creating and attaching a volume is
# cheap to automate; formatting one is a one-way operation, and a
# script that runs mkfs against whatever is at that path is a script
# that will eventually destroy someone's snapshots. Same posture as the
# droplet resize above: the destructive step stays in a human's hands.
# Both sentinels are checked as well as the mount, and the container
# re-checks them at every start. A `nofail` fstab entry means a reboot
# where the volume does not come back still boots the box, and a bind
# mount onto a bare directory would put sealed snapshots — or worse,
# an EMPTY bookkeeping database — on the root filesystem. `mountpoint`
# here only ever proves something about deploy time.
#
# The two are diagnosed separately because they fail for different
# reasons and have different fixes: an absent mount is a volume
# problem, a mounted volume with no sentinel is a setup step that was
# skipped.
info "Checking the backup block volume..."
if ! ssh_do "mountpoint -q /mnt/onym-backup"; then
    err "/mnt/onym-backup is not a mountpoint on the droplet."
    err ""
    err "The backup operator stores sealed snapshots and the bookkeeping"
    err "that accounts for them there, and it must not be the root"
    err "filesystem — filling that takes the relay and the authority down"
    err "with it."
    err ""
    err "Provision it (idempotent; safe to rerun):"
    err "  ./deploy/digitalocean/provision-volume.sh"
    err "or the \"Provision backup volume\" workflow in Actions."
    exit 1
fi
if ! ssh_do "test -f /mnt/onym-backup/blobs/.onym-backup-volume && test -f /mnt/onym-backup/state/.onym-backup-volume"; then
    err "/mnt/onym-backup is mounted, but the backup directories are not set up."
    err ""
    err "Rows and bytes live on the same volume on purpose: the operator"
    err "reconciles before serving and deletes bytes no row accounts for,"
    err "so a fresh database against a populated volume erases every"
    err "snapshot on first boot. The sentinels are how the container tells"
    err "a mounted volume from the bare directory after a reboot where the"
    err "mount did not return, and the ownership is because the operator"
    err "runs unprivileged."
    err ""
    err "The same script prepares all of it:"
    err "  ./deploy/digitalocean/provision-volume.sh"
    exit 1
fi
ok "  /mnt/onym-backup is mounted and prepared"

NO_BUILD=""
if [ -n "$DOCR_NAME" ]; then
    NO_BUILD="--no-build"
    info "Granting the droplet read-only registry access..."
    # Read-only on purpose. The droplet pulls; nothing running on it
    # should be able to push an image back into the registry that the
    # next deploy will trust. Note this writes the whole docker config
    # — the droplet has no other registry credentials to preserve.
    doctl registry docker-config --read-only --expiry-seconds "$DOCR_CRED_TTL" \
        | ssh_do "install -m 700 -d /root/.docker && cat > /root/.docker/config.json"

    info "Pulling images on the droplet..."
    ssh_do "cd /opt/onym-infra && docker compose pull"
else
    info "Building containers serially (five Rust builds; the first run takes a while)..."
    ssh_do "cd /opt/onym-infra && COMPOSE_PARALLEL_LIMIT=1 docker compose build"
fi

# The upstream manifest is a reference template: its all-zero operator
# cannot verify a verdict and the authority correctly refuses to boot
# against it. Derive the public half from the deployment secret inside
# the built image, then materialize the exact manifest this authority
# will publish. The seed never leaves authority.env or the container.
info "Materializing authority manifest for $AUTHORITY_HOST..."
if ! OPERATOR_KEY="$(ssh_do "cd /opt/onym-infra && docker compose run --rm --no-deps \
    authority onym-moderation-authority derive-operator-key")"; then
    err "authority could not derive its operator key; check AUTHORITY_SIGNING_SEED."
    exit 1
fi
[[ "$OPERATOR_KEY" =~ ^onym:key:[0-9a-f]{64}$ ]] \
    || { err "authority returned an invalid operator key: $OPERATOR_KEY"; exit 1; }

# The manifest and its signature move as a PAIR, and the failure mode
# between the two must always be "signature missing", never "signature
# covers different bytes": a stale .sig next to new manifest bytes
# looks healthy (the running authority serves its in-memory copy) and
# detonates on the next container restart, when every hard-verifying
# client rejects the manifest at once. Ordering: materialize to a
# staging name, finalize it for discovery review, sign the staged
# bytes, and only THEN touch the live pair — so a finalize or signing
# failure (image predating its subcommand, docker hiccup) leaves the
# previous manifest+signature pair fully intact, and any later
# interruption degrades to a missing signature.
ssh_do "python3 /opt/onym-infra/deploy/digitalocean/materialize-authority-manifest.py \
    /opt/onym-infra/moderation/authority/manifest/manifest.json \
    /opt/onym-infra/runtime/authority-manifest/manifest.json.next \
    $OPERATOR_KEY $AUTHORITY_HOST"
ok "Authority manifest names $OPERATOR_KEY"

# Finalize the staged manifest for the clients' discovery-seat review:
# inject the top-level `name` and `endpoints` the catalog adapters
# read, and embed the operator's Ed25519 signature over the discovery
# profile's canonical signing bytes — without it, destination-manifest
# review rejects and the discovery catalog cannot carry the authority
# row. Runs inside the authority image because embedding needs the
# signing seed, which never leaves authority.env — same posture as
# derive-operator-key. The service's own /manifest mount stays :ro;
# the rewrite goes through a run-scoped rw mount at /manifest-rw
# instead, and only touches the staged file, never the live pair.
# `name` and the endpoint URL come from AUTHORITY_MANIFEST_NAME and
# AUTHORITY_PUBLIC_URL, defaulted in docker-compose.yml.
info "Finalizing authority manifest for discovery review..."
if ! ssh_do "cd /opt/onym-infra && docker compose run --rm --no-deps \
    --volume /opt/onym-infra/runtime/authority-manifest:/manifest-rw \
    authority onym-moderation-authority finalize-manifest /manifest-rw/manifest.json.next"; then
    err "authority could not finalize the manifest; is the image built from a"
    err "moderation submodule that has the finalize-manifest subcommand?"
    err "(The live manifest and its signature were not touched.)"
    exit 1
fi

# Sign the exact staged bytes inside the authority image, so the seed
# stays in authority.env — same posture as derive-operator-key
# (onym-infra#4). The published body is base64 + a trailing LF; the
# iOS verifier trims whitespace before decoding
# (SignedAsset.decodeSignature), and that contract is pinned in the
# README.
info "Signing authority manifest..."
if ! MANIFEST_SIG="$(ssh_do "cd /opt/onym-infra && docker compose run --rm --no-deps \
    authority onym-moderation-authority sign-manifest /manifest/manifest.json.next")"; then
    err "authority could not sign the manifest; is the image built from a"
    err "moderation submodule that has the sign-manifest subcommand?"
    err "(The live manifest and its signature were not touched.)"
    exit 1
fi
[[ "$MANIFEST_SIG" =~ ^[A-Za-z0-9+/]{86}==$ ]] \
    || { err "authority returned an invalid manifest signature: $MANIFEST_SIG"; exit 1; }
# Retire the old signature, publish the new manifest, then its
# signature — at every instant the published signature either matches
# the published manifest or is absent.
ssh_do "rm -f /opt/onym-infra/runtime/authority-manifest/manifest.json.sig \
    && mv /opt/onym-infra/runtime/authority-manifest/manifest.json.next \
          /opt/onym-infra/runtime/authority-manifest/manifest.json \
    && printf '%s\n' '$MANIFEST_SIG' > /opt/onym-infra/runtime/authority-manifest/manifest.json.sig.tmp \
    && mv /opt/onym-infra/runtime/authority-manifest/manifest.json.sig.tmp \
          /opt/onym-infra/runtime/authority-manifest/manifest.json.sig"
ok "Authority manifest signature published"

info "Starting containers..."
# Force Authority recreation even when only the materialized manifest
# changed. It reads the exact bytes once at boot; updating the bind
# mount without restarting would leave the old manifest in memory.
ssh_do "cd /opt/onym-infra && docker compose up -d --no-deps --force-recreate $NO_BUILD authority && docker compose up -d $NO_BUILD"

# ─── Verify ───────────────────────────────────────────────────────────

info "Verifying (certs may take ~30s on first issue)..."
sleep 20
check() {
    local url="$1" label="$2" code
    code="$(curl -o /dev/null -s -w '%{http_code}' --max-time 15 "$url" 2>/dev/null || true)"
    [ -n "$code" ] || code=000
    if [ "$code" != "000" ]; then ok "  $label — HTTP $code (TLS OK)"; else warn "  $label — no response yet (cert may still be issuing)"; fi
}
# The moderation endpoints have a right answer, so "anything but 000"
# is not good enough for them: a 502 means Caddy is up and the thing
# behind it is not, and a 404 on a policy URL means a published term is
# unreachable. Both are exactly the failures worth catching.
check_health() {
    local url="$1" label="$2" hint="${3:-}" code
    code="$(curl -o /dev/null -s -w '%{http_code}' --max-time 15 "$url" 2>/dev/null || true)"
    [ -n "$code" ] || code=000
    case "$code" in
        200) ok "  $label — HTTP 200" ;;
        000) warn "  $label — no response yet (cert may still be issuing)" ;;
        *)   err "  $label — HTTP $code, expected 200.${hint:+ $hint}"; HEALTH_FAILURES=1 ;;
    esac
}
HEALTH_FAILURES=0
check "https://$RELAYER_HOST/" "relayer"   # expect 401/422 (auth/validation) = up
check "https://$BLOSSOM_HOST/" "blossom"
check "https://$NOSTR_HOST/"   "nostr"     # expect 400/426 on plain GET = up
# check(), not check_health(): before the first onym-discovery publish
# the web root is empty and 404 is the CORRECT answer — what this
# proves is that the vhost loaded and TLS was issued. Once a publish
# has landed, the onym-discovery workflow's own health gate checks the
# served bytes byte-for-byte; this stack only owes the vhost.
check "https://$DISCOVERY_HOST/manifest.json" "discovery"
check_health "https://$MODERATION_HOST/health" "moderation" "Check: docker compose logs moderation"
check_health "https://$MODERATION_ANDROID_HOST/health" "moderation-android" "Check: docker compose logs moderation-android"
check_health "https://$AUTHORITY_HOST/health"  "authority"  "Check: docker compose logs authority"
# The backup operator gets the same three checks as the authority, and
# for the same reason: clients pin these bytes. Without them a container
# that failed to boot — an invalid-but-well-shaped signing seed, an
# unwritable blob root, the volume sentinel missing — deploys green,
# and the first person to find out is a holder whose upload 502s.
check_health "https://$BACKUP_HOST/health" "backup" \
    "Check: docker compose logs backup (a missing volume sentinel refuses to start, by design)"
check_health "https://$BACKUP_HOST/manifest.json" "backup manifest" \
    "Check: docker compose logs backup"
# Consent pins the manifest bytes; a 404 here leaves every client
# unable to check what it agreed to against what is served.
check_health "https://$BACKUP_HOST/manifest.json.sig" "backup manifest signature" \
    "Check: docker compose logs backup"
# A term nobody can read is a term nobody agreed to, so the published
# documents are checked like a service rather than assumed. /policy/csam
# is one of the nine the manifest links to, and the heaviest.
check_health "https://$AUTHORITY_HOST/policy/csam" "policy documents" \
    "The manifest links here; a 404 means the submodule is not checked out on the droplet."
# The endpoint the whole trust chain hangs on, checked like a service.
check_health "https://$AUTHORITY_HOST/manifest.json" "manifest" \
    "Check: docker compose logs authority"
# Clients verify the manifest against this before trusting its terms;
# a 404 here forces every client back to soft-verified acceptance.
check_health "https://$AUTHORITY_HOST/manifest.json.sig" "manifest signature" \
    "Check that deploy signed the manifest and Caddy mounts runtime/authority-manifest."
# Publication is not correctness: prove the SERVED pair is the pair
# this deploy produced — the served signature must be the one just
# minted, over manifest bytes identical to the file it signed. (No
# local crypto needed: sig == minted sig AND served bytes == signed
# bytes ⇒ the signature verifies.) Every remote/network command below
# is failure-guarded: under `set -e` a transient failure here would
# otherwise abort a deploy that already succeeded, with no message.
SERVED_SIG="$(curl -fsS --max-time 15 "https://$AUTHORITY_HOST/manifest.json.sig" 2>/dev/null | tr -d '[:space:]' || true)"
# Hash curl's raw output inside the pipeline. Capturing the body in a
# shell variable strips its trailing LF, changing the bytes the hash
# covers. The assignment lives in an `if` so `set -e` does not abort;
# `pipefail` makes a failed curl take the else branch instead of
# reporting the hash of empty stdin.
SERVED_MANIFEST_HASH=""
if HASHED_MANIFEST="$(
    curl -fsS --max-time 15 "https://$AUTHORITY_HOST/manifest.json" 2>/dev/null \
        | shasum -a 256 \
        | cut -d' ' -f1
)"; then
    SERVED_MANIFEST_HASH="$HASHED_MANIFEST"
fi
if [ -n "$SERVED_SIG" ] && [ -n "$SERVED_MANIFEST_HASH" ]; then
    PAIR_OK=1
    if [ "$SERVED_SIG" != "$MANIFEST_SIG" ]; then
        err "  served manifest.json.sig differs from the signature this deploy produced."
        HEALTH_FAILURES=1; PAIR_OK=0
    fi
    # `shasum` locally (macOS has no sha256sum); `sha256sum` remotely
    # (coreutils is guaranteed on the droplet; perl's shasum is not).
    SIGNED_MANIFEST_HASH="$(ssh_do "sha256sum /opt/onym-infra/runtime/authority-manifest/manifest.json | cut -d' ' -f1" || true)"
    if [ -z "$SIGNED_MANIFEST_HASH" ]; then
        warn "  could not hash the signed manifest on the droplet; served-pair check incomplete."
        PAIR_OK=0
    elif [ "$SERVED_MANIFEST_HASH" != "$SIGNED_MANIFEST_HASH" ]; then
        err "  served manifest.json differs from the bytes the signature covers"
        err "  (the authority is still serving its previous in-memory manifest?)."
        HEALTH_FAILURES=1; PAIR_OK=0
    fi
    if [ "$PAIR_OK" -eq 1 ]; then
        ok "  manifest signature covers the served bytes"
    fi
else
    # A green deploy must never be mistaken for a verified pair: this
    # check is the precondition for enforceManifestSignatures.
    warn "  manifest signature NOT verified — could not fetch the served pair (cert may still be issuing)."
fi

[ "$HEALTH_FAILURES" -eq 0 ] \
    || { err "One or more moderation endpoints returned a definite non-200 response."; exit 1; }

echo
ok "Done. Droplet $DROPLET_ID @ $DROPLET_IP"
if [ -n "$DOCR_NAME" ]; then
    echo "  Images:     $RELAYER_IMAGE"
    echo "              $MODERATION_IMAGE"
    echo "              $MODERATION_ANDROID_IMAGE"
    echo "              $AUTHORITY_IMAGE"
fi
echo "  Nostr:      wss://$NOSTR_HOST"
echo "  Blossom:    https://$BLOSSOM_HOST"
echo "  Relayer:    https://$RELAYER_HOST"
echo "  Moderation: https://$MODERATION_HOST"
echo "  Moderation (Android): https://$MODERATION_ANDROID_HOST"
echo "  Authority:  https://$AUTHORITY_HOST"
echo "  Discovery:  https://$DISCOVERY_HOST (static; published by onym-discovery's Deploy workflow)"
echo "  Logs:       ssh -i $SSH_KEY_PATH root@$DROPLET_IP 'cd /opt/onym-infra && docker compose logs -f'"
# The authority cannot verify a mandate's countersignature until it
# knows the interface's public key, and that key only exists once the
# interface has booted. Point at it rather than leaving the operator to
# discover the dependency from a rejected mandate.
if [ -z "${AUTHORITY_INTERFACE_KEY:-}" ]; then
    echo
    warn "AUTHORITY_INTERFACE_KEY is unset. Read interfaceKey from"
    warn "  https://$MODERATION_HOST/health, set it in .env (or the repo variable), and re-run."
fi
if [ -z "${AUTHORITY_INTERFACE_KEYS_BY_COMPONENT:-}" ]; then
    echo
    warn "AUTHORITY_INTERFACE_KEYS_BY_COMPONENT is unset — Android mandates cannot register."
    warn "Read interfaceKey from https://$MODERATION_ANDROID_HOST/health and set"
    warn "  AUTHORITY_INTERFACE_KEYS_BY_COMPONENT=onym:component:onym-android=<that key>"
    warn "in .env (or the repo variable), then re-run."
fi
