#!/usr/bin/env bash
#
# Provision the device-backup block volume, idempotently.
#
# `deploy.sh` refuses to deploy unless /mnt/onym-backup is a prepared
# mountpoint. That gate is deliberate and stays; this script is what
# satisfies it, so the preparation stops being a manual runbook step
# without becoming a step nobody sees.
#
# **It never runs mkfs.** The only formatting that happens is
# `doctl compute volume create --fs-type ext4`, which formats a volume
# at the moment it is created — when it is definitionally empty. A
# volume that already exists is mounted, never reformatted, and one
# that exists with no filesystem is refused rather than repaired. That
# is the one property worth protecting here: a provisioning script that
# can format a populated volume will eventually delete someone's only
# copy of their backup, and it will do it on a rerun that looked
# routine.
#
# Everything else is create-if-absent: the volume, the attachment, the
# mount, the fstab line, the directories, the sentinels, the ownership.
# Running it twice changes nothing the second time.
#
#   DO_API_KEY=... ./deploy/digitalocean/provision-volume.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_FILE="$REPO_ROOT/.env"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}==> $*${NC}"; }
ok()    { echo -e "${GREEN}==> $*${NC}"; }
warn()  { echo -e "${YELLOW}==> $*${NC}"; }
err()   { echo -e "${RED}==> ERROR: $*${NC}" >&2; }

# .env is optional: CI supplies these as environment variables instead.
[ -f "$ENV_FILE" ] && { set -a; source "$ENV_FILE"; set +a; }

: "${DO_API_KEY:?set DO_API_KEY}"
DO_REGION="${DO_REGION:-ams3}"
DROPLET_NAME="${DROPLET_NAME:-onym-infra}"
VOLUME_NAME="${BACKUP_VOLUME_NAME:-onym-backup}"
VOLUME_SIZE="${BACKUP_VOLUME_SIZE:-100GiB}"
MOUNT="${BACKUP_VOLUME_MOUNT:-/mnt/onym-backup}"
# The uid the operator image runs as. A root-owned mount leaves it
# unable to write, which the mountpoint check alone would not catch.
OPERATOR_UID="${BACKUP_OPERATOR_UID:-10001}"
SSH_KEY_PATH="${SSH_KEY_PATH:-$HOME/.ssh/id_ed25519}"
SSH_KEY_PATH="${SSH_KEY_PATH/#\~/$HOME}"
[ -f "$SSH_KEY_PATH" ] || { err "SSH key not found at $SSH_KEY_PATH"; exit 1; }

export DIGITALOCEAN_ACCESS_TOKEN="$DO_API_KEY"
for cmd in doctl ssh; do
    command -v "$cmd" >/dev/null 2>&1 || { err "$cmd is not on PATH."; exit 1; }
done

# ─── Droplet ──────────────────────────────────────────────────────────
# Resolved, never created. `deploy.sh` owns droplet lifecycle; this
# script attaches a volume to a box that already exists, and a droplet
# conjured here would be one that never got the stack deployed to it.
info "Resolving droplet $DROPLET_NAME..."
DROPLET_ID="${DROPLET_ID:-$(doctl compute droplet list "$DROPLET_NAME" --format ID --no-header 2>/dev/null | head -1)}"
[ -n "$DROPLET_ID" ] || { err "No droplet named $DROPLET_NAME. Run deploy.sh first — it creates or reuses the box."; exit 1; }
DROPLET_IP="$(doctl compute droplet get "$DROPLET_ID" --format PublicIPv4 --no-header)"
[ -n "$DROPLET_IP" ] || { err "Droplet $DROPLET_ID has no public IPv4 yet."; exit 1; }
ok "  droplet $DROPLET_ID ($DROPLET_IP)"

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 -i "$SSH_KEY_PATH")
ssh_do() { ssh "${SSH_OPTS[@]}" "root@$DROPLET_IP" "$@"; }

# ─── Volume ───────────────────────────────────────────────────────────
info "Resolving volume $VOLUME_NAME in $DO_REGION..."
VOLUME_ID="$(doctl compute volume list --region "$DO_REGION" --format Name,ID --no-header 2>/dev/null \
    | awk -v n="$VOLUME_NAME" '$1 == n { print $2; exit }')"

if [ -n "$VOLUME_ID" ]; then
    ok "  reusing volume $VOLUME_ID"
else
    # --fs-type ext4 formats at creation. Safe precisely because the
    # volume did not exist a moment ago, so there is nothing on it to
    # lose. This is the ONLY formatting this script performs.
    info "  creating $VOLUME_NAME ($VOLUME_SIZE, ext4)"
    VOLUME_ID="$(doctl compute volume create "$VOLUME_NAME" \
        --region "$DO_REGION" --size "$VOLUME_SIZE" --fs-type ext4 \
        --format ID --no-header)"
    [ -n "$VOLUME_ID" ] || { err "Volume creation returned no id."; exit 1; }
    ok "  created $VOLUME_ID"
fi

ATTACHED="$(doctl compute volume get "$VOLUME_ID" --format DropletIDs --no-header 2>/dev/null | tr -d '[]" ')"
case ",$ATTACHED," in
    *",$DROPLET_ID,"*)
        ok "  already attached to $DROPLET_ID" ;;
    ,,|,)
        info "  attaching to droplet $DROPLET_ID"
        doctl compute volume-action attach "$VOLUME_ID" "$DROPLET_ID" --wait >/dev/null
        ok "  attached" ;;
    *)
        # Moving a volume between droplets is a data-bearing decision,
        # not a reconciliation this script should make on its own.
        err "Volume $VOLUME_ID is attached to droplet(s) $ATTACHED, not $DROPLET_ID."
        err "Detach it deliberately if that is what you want:"
        err "  doctl compute volume-action detach $VOLUME_ID <CURRENT_DROPLET_ID> --wait"
        exit 1 ;;
esac

# ─── Mount and prepare ────────────────────────────────────────────────
DEVICE="/dev/disk/by-id/scsi-0DO_Volume_${VOLUME_NAME}"

info "Preparing $MOUNT on the droplet..."
ssh_do "OPERATOR_UID='$OPERATOR_UID' DEVICE='$DEVICE' MOUNT='$MOUNT' bash -s" <<'REMOTE'
set -euo pipefail

if ! mountpoint -q "$MOUNT"; then
    [ -b "$DEVICE" ] || { echo "ERROR: $DEVICE is not a block device — is the volume attached?" >&2; exit 1; }
    # Refuse rather than repair. An attached volume with no filesystem
    # is either brand new and created without --fs-type, or something
    # nobody understands yet; formatting it here is how a rerun eats
    # data that a human would have recognised.
    if ! blkid "$DEVICE" >/dev/null 2>&1; then
        echo "ERROR: $DEVICE has no filesystem." >&2
        echo "Not formatting it: this script never runs mkfs, because a" >&2
        echo "rerun that formats a populated volume destroys the only" >&2
        echo "copy of someone's backup. If it really is empty:" >&2
        echo "  mkfs.ext4 $DEVICE" >&2
        exit 1
    fi
    mkdir -p "$MOUNT"
    mount -o discard,defaults "$DEVICE" "$MOUNT"
    echo "mounted $DEVICE at $MOUNT"
else
    echo "$MOUNT already mounted"
fi

# nofail so a missing volume does not stop the box booting. The
# container's sentinel check is what stops it writing to the root
# filesystem in that case — see docker-compose.yml.
FSTAB_LINE="$DEVICE $MOUNT ext4 defaults,nofail,discard 0 2"
if ! grep -qsF "$MOUNT " /etc/fstab; then
    echo "$FSTAB_LINE" >> /etc/fstab
    echo "added fstab entry"
else
    echo "fstab entry already present"
fi

# Two directories, so the blob root contains nothing but shard
# directories. The sentinels are how the container tells a mounted
# volume from the bare directory underneath after a reboot where the
# mount did not return.
mkdir -p "$MOUNT/blobs" "$MOUNT/state"
touch "$MOUNT/blobs/.onym-backup-volume" "$MOUNT/state/.onym-backup-volume"
chown -R "$OPERATOR_UID:$OPERATOR_UID" "$MOUNT"

# Post-condition: exactly what deploy.sh's gate will check.
mountpoint -q "$MOUNT"
test -f "$MOUNT/blobs/.onym-backup-volume"
test -f "$MOUNT/state/.onym-backup-volume"
test "$(stat -c '%u' "$MOUNT/blobs")" = "$OPERATOR_UID"
echo "prepared: $(df -h "$MOUNT" | tail -1)"
REMOTE

ok "$MOUNT is mounted and prepared — deploy.sh's gate will pass."
