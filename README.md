# onym-infra

Consolidated backend for **onym.app**, on a single DigitalOcean droplet
via Docker Compose:

| Service | Host | What |
|---|---|---|
| **Caddy** | — | reverse proxy + automatic HTTPS (Let's Encrypt, auto-renew) |
| **strfry** | `nostr.onym.app` | Nostr relay |
| **blossom** | `blossom.onym.app` | media/blob server |
| **relayer** | `relayer.onym.app` | Soroban contract relayer (git submodule → [`onym-relayer`](https://github.com/onymchat/onym-relayer)) |
| **moderation** | `moderation.onym.app` | moderation enforcement backend — holds the Apple DeviceCheck key and is the only thing that can mark a device (git submodule → [`onym-moderation`](https://github.com/onymchat/onym-moderation), `apple/`) |
| **authority** | `authority.onym.app` | moderation authority — opens and decides cases and signs verdicts, with no Apple credentials and no way to mark a device itself (same submodule, `authority/`) |

The two moderation services are one seat split in half on purpose: the
authority can judge but not enforce, the interface can enforce but not
judge. `onym-moderation` ships each as a standalone stack with its own
Caddy; here they are folded into this one, and the authority reaches
the interface over the private network rather than the public internet.

TLS is handled entirely by Caddy — no certbot, no cron, no manual
renewals. Certificates are provisioned on first request and renewed
automatically, so the expiry problem the old `stellar-mls` box had
can't recur.

## Prerequisites

- `doctl`, `ssh`, `rsync`, `curl`, `python3`, `dig` on your machine
- An SSH key (default `~/.ssh/id_ed25519`)
- A DigitalOcean API token and a Cloudflare API token with `DNS:Edit`
  on the `onym.app` zone

## First-time setup

```bash
git clone --recurse-submodules <this repo> onym-infra
cd onym-infra

cp .env.example .env                        # DO_API_KEY, CF_API_TOKEN, hosts, size...
cp relayer.env.example relayer.env          # RELAYER_SECRET_KEY (required), RELAYER_AUTH_TOKENS...
cp moderation.env.example moderation.env    # DeviceCheck key + ids, interface signing seed...
cp authority.env.example authority.env      # AUTHORITY_SIGNING_SEED (required), tokens...

# The authority serves its manifest byte-for-byte, because users'
# mandates pin its SHA-256. It is your published document, so it is not
# in the submodule — put yours here before deploying.
mkdir -p moderation/authority/manifest
cp moderation/authority/manifest.example.json \
   moderation/authority/manifest/manifest.json

./deploy/digitalocean/deploy.sh
```

The script creates (or reuses) an `s-1vcpu-2gb` droplet, adds a 2 GB
swapfile so the Rust builds don't OOM, creates **DNS-only** (grey-cloud)
Cloudflare A records for all five hosts, syncs this repo, and brings the
stack up. It records the droplet ID/IP back into `.env` so re-runs reuse
the box.

> The swapfile is written by cloud-init, which only runs when the
> droplet is **created**. Three Rust builds now share that 2 GB box;
> if they start OOMing, adding swap on an existing droplet is a manual
> `ssh` job, not something re-running this script will do for you.

> The Cloudflare records must stay **DNS-only** (grey cloud). Proxying
> them through Cloudflare breaks Caddy's ACME challenge and the Nostr
> `wss://` connection — that orange-cloud-on-the-root-domain mistake is
> exactly what silently broke cert renewal on the old stack.

## Updating

- **Config/compose change:** edit and re-run `deploy.sh` (re-syncs +
  `docker compose up -d`).
- **Relayer code:** bump the submodule (`git -C relayer pull`), commit,
  re-run `deploy.sh` (rebuilds the image).
- **Moderation code:** same shape — `git -C moderation pull`, commit,
  re-run `deploy.sh`.
- **The authority manifest:** editing
  `moderation/authority/manifest/manifest.json` after anyone has
  consented silently invalidates their mandates, because a mandate pins
  the SHA-256 of those exact bytes. Republish deliberately.

## Bringing the moderation services up for the first time

Two values only exist after a boot, so the first deploy is a two-pass
affair:

1. Deploy with `MODERATION_ENFORCE_SIGNATURES=false` and
   `AUTHORITY_INTERFACE_KEY=` empty. Until signatures are enforced,
   whatever holds the shared authority token can ban a device, so
   treat this as a window to get through rather than a state to sit in.
2. Read the interface's public countersigning key out of the logs
   (`docker compose logs moderation`, the `interface countersigning
   key` line), set it as `AUTHORITY_INTERFACE_KEY`, set
   `MODERATION_ENFORCE_SIGNATURES=true`, and re-run.

## Deploy via GitHub Actions

`.github/workflows/deploy.yml` runs the same `deploy.sh` from CI
(manual `workflow_dispatch`). It writes `.env`, `relayer.env`,
`moderation.env` and `authority.env` from repo Secrets/Variables, so
nothing sensitive is committed. This is the relayer's deployment path
now — the `onym-relayer` repo only publishes `relayers.json`; it no
longer deploys a droplet.

Configure once under **Settings → Secrets and variables → Actions**:

- **Secrets:** `DO_API_KEY`, `CF_API_TOKEN`, `SSH_PRIVATE_KEY`,
  `RELAYER_SECRET_KEY`, and optionally `RELAYER_AUTH_TOKENS`.
- **Moderation secrets:** `MODERATION_DEVICECHECK_KEY_PEM` (the `.p8`
  contents, newlines as `\n`), `MODERATION_DEVICECHECK_KEY_ID`,
  `MODERATION_DEVICECHECK_TEAM_ID`, `MODERATION_INTERFACE_SIGNING_SEED`,
  `AUTHORITY_SIGNING_SEED`, `MODERATION_AUTHORITY_TOKEN` (the same value
  serves as the authority's `AUTHORITY_INTERFACE_TOKEN`),
  `AUTHORITY_MODERATOR_TOKEN`, `AUTHORITY_ADMIN_TOKEN`, and optionally
  `MODERATION_AUDIT_TOKEN`.
- **Variables** (all optional; defaults in the workflow):
  `DOMAIN`, `NOSTR_HOST`, `BLOSSOM_HOST`, `RELAYER_HOST`,
  `MODERATION_HOST`, `AUTHORITY_HOST`, `MODERATION_DEVICECHECK_ENV`,
  `MODERATION_ENFORCE_SIGNATURES`, `AUTHORITY_INTERFACE_KEY`,
  `CADDY_EMAIL`, `DO_REGION`, `DO_DROPLET_SIZE`, and `DROPLET_ID`.

`AUTHORITY_INTERFACE_KEY` is a variable and not a secret because it is
a *public* key, and because it does not exist until the interface has
booted once — see the two-pass first deploy above.

Re-runs are idempotent: `deploy.sh` reuses the existing droplet named
`onym-infra` (adopting it by name), so repeat CI runs **update** the box
rather than creating new ones — even though CI rebuilds `.env` each run.
Setting the `DROPLET_ID` variable is optional; it just skips the
name lookup. DNS records are upserted, not duplicated.

`SSH_PRIVATE_KEY` must be a key the droplet trusts. On the very first
deploy the droplet is created with it; on later runs the same key must
still be authorized (use the same secret across runs).

## Operating

```bash
ssh -i ~/.ssh/id_ed25519 root@<DROPLET_IP>
cd /opt/onym-infra
docker compose ps
docker compose logs -f caddy        # cert issuance / renewal
docker compose logs -f relayer
docker compose logs -f moderation   # boots with the countersigning key
docker compose logs -f authority
```

Both moderation services answer `GET /health`, which `deploy.sh` checks
for a 200 at the end of a run.

## Migration notes (from stellar-mls)

- Dropped: `pn-relay`, `ceremony-coordinator`, the static website, and
  the legacy `relay.onym.chat` relayer alias.
- The standalone `relayer.onym.chat` box is **not** touched by this repo.
- After the new box is verified, destroy the old `onym-chat` droplet.
- App-side follow-up: point the client's `relayers.json` and the Nostr
  relay seed at the `*.onym.app` hosts.
- Deploy ownership moved here: the `onym-relayer` `Release` workflow was
  trimmed to publish `relayers.json` only; this repo's `Deploy` workflow
  owns standing up the relayer (with nostr + blossom) on the box.
