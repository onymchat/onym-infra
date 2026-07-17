# onym-infra

Consolidated backend for **onym.app**, on a single DigitalOcean droplet
via Docker Compose:

| Service | Host | What |
|---|---|---|
| **Caddy** | — | reverse proxy + automatic HTTPS (Let's Encrypt, auto-renew) |
| **strfry** | `nostr.onym.app` | Nostr relay |
| **blossom** | `blossom.onym.app` | media/blob server |
| **relayer** | `relayer.onym.app` | Soroban contract relayer (git submodule → [`onym-relayer`](https://github.com/onymchat/onym-relayer)) |

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

cp .env.example .env                 # DO_API_KEY, CF_API_TOKEN, hosts, size...
cp relayer.env.example relayer.env   # RELAYER_SECRET_KEY (required), RELAYER_AUTH_TOKENS...

./deploy/digitalocean/deploy.sh
```

The script creates (or reuses) an `s-1vcpu-2gb` droplet, adds a 2 GB
swapfile so the Rust relayer builds without OOM, creates **DNS-only**
(grey-cloud) Cloudflare A records for the three hosts, syncs this repo,
and brings the stack up. It records the droplet ID/IP back into `.env`
so re-runs reuse the box.

> The Cloudflare records must stay **DNS-only** (grey cloud). Proxying
> them through Cloudflare breaks Caddy's ACME challenge and the Nostr
> `wss://` connection — that orange-cloud-on-the-root-domain mistake is
> exactly what silently broke cert renewal on the old stack.

## Updating

- **Config/compose change:** edit and re-run `deploy.sh` (re-syncs +
  `docker compose up -d`).
- **Relayer code:** bump the submodule (`git -C relayer pull`), commit,
  re-run `deploy.sh` (rebuilds the image).

## Deploy via GitHub Actions

`.github/workflows/deploy.yml` runs the same `deploy.sh` from CI
(manual `workflow_dispatch`). It writes `.env` / `relayer.env` from repo
Secrets/Variables, so nothing sensitive is committed. This is the
relayer's deployment path now — the `onym-relayer` repo only publishes
`relayers.json`; it no longer deploys a droplet.

Configure once under **Settings → Secrets and variables → Actions**:

- **Secrets:** `DO_API_KEY`, `CF_API_TOKEN`, `SSH_PRIVATE_KEY`,
  `RELAYER_SECRET_KEY`, and optionally `RELAYER_AUTH_TOKENS`.
- **Variables** (all optional; defaults in the workflow):
  `DOMAIN`, `NOSTR_HOST`, `BLOSSOM_HOST`, `RELAYER_HOST`, `CADDY_EMAIL`,
  `DO_REGION`, `DO_DROPLET_SIZE`, and `DROPLET_ID`.

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
```

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
