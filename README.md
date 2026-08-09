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
Caddy; here they are folded into this one.

They share a box for cost, and nothing depends on it. In the contract
they are separate operators, so the authority delivers verdicts to the
interface's **public** hostname rather than over this network — the day
the interface moves to its own droplet, or to a vendor who is not us,
that address points somewhere else and nothing else changes. It also
means this deployment exercises the same TLS-plus-token-plus-signature
path every other deployment has to use.

The one thing that genuinely must stay on the private network is the
triage model container, if it is ever enabled: case evidence was
disclosed for adjudication, and sending it to a third party is a
further disclosure. Different relationship, different rule.

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
cp authority.env.example authority.env      # signing seed + admin token (required), API token...

./deploy/digitalocean/deploy.sh
```

The authority's reference manifest and the policy documents its terms
link to ship in the `moderation` submodule, so the submodule has to be
checked out (`git submodule update --init --recursive` if you cloned
without `--recurse-submodules`). At deploy time the script derives the
authority's public operator key from `AUTHORITY_SIGNING_SEED` inside the
built container and materializes the deployment manifest. It also
rewrites the reference policy origin to `AUTHORITY_HOST`, so staging
does not send users to production. The seed itself never leaves the
secret env file or container.

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
- **The authority manifest and policy documents:** the reference
  template and policy documents change by bumping the submodule. The
  deployed manifest is materialized from that template with the
  deployment's operator key and `AUTHORITY_HOST`. Changing any of those
  bytes after consent creates a new manifest hash, so existing mandates
  remain bound to the old terms and fresh consent is required.

## Bringing the moderation services up for the first time

Only the interface countersigning key settles after a boot, so the first
deploy is a two-pass affair without an unsigned enforcement window:

1. Generate both signing seeds, leave `AUTHORITY_INTERFACE_KEY=` empty,
   keep `MODERATION_ENFORCE_SIGNATURES=true`, and deploy. The script
   derives the authority operator key before startup and materializes a
   matching manifest, so the authority boots and every accepted verdict
   is signed from the first request.
2. Read the interface's public key from its health response, set it as
   `AUTHORITY_INTERFACE_KEY`, and re-run:

   ```bash
   curl -fsS https://moderation.onym.app/health \
     | python3 -c 'import json,sys; print(json.load(sys.stdin)["interfaceKey"])'
   ```

Until pass two, the authority cannot validate a newly registered
mandate's interface countersignature and refuses it. That is a closed
bootstrap state, not permission to accept unsigned verdicts.

## The published policy documents

The materialized manifest's terms link to
`https://$AUTHORITY_HOST/policy/…` — nine documents a user reads
*before* consenting, one per term and one per violation class. A 404
there means the term was never published, so Caddy serves them from
`moderation/authority/published/` rather than leaving them to the
application, which routes only `/manifest.json` and `/v1/*`.

There are no `#fragment` links: each class is its own document, so a
`definition` URL resolves to exactly the text it names. The documents
are served as the published Markdown itself
(`text/markdown; charset=utf-8`) rather than rendered to HTML — these
are the bytes that were signed off, and serving them verbatim keeps
what a user reads identical to what was reviewed.

## The manifest signature

`https://$AUTHORITY_HOST/manifest.json.sig` is the detached Ed25519
operator signature over the **exact bytes** of the published
`manifest.json`. Clients (the iOS `SignedAsset` verifier) fetch it and
verify the manifest against the directory-pinned operator key before
trusting the terms inside; while it 404s they can only accept the
manifest soft-verified.

`deploy.sh` produces it on every deploy: the manifest is materialized
to a staging name, signed **inside the authority image** (the seed
never leaves `authority.env`, same as `derive-operator-key`), and only
then is the live pair touched — old signature retired, new manifest
moved into place, new signature written last. A signing failure leaves
the previous manifest+signature pair fully intact; any later
interruption degrades to a missing signature (404 → soft-verify). At
no instant can the published signature cover different bytes than the
published manifest.

Wire contract, pinned here because two repos depend on it: the body is
**base64 of the 64-byte raw signature, plus a trailing LF** — 89 bytes
total. The iOS verifier trims whitespace before decoding
(`SignedAsset.decodeSignature`); any other consumer must do the same.

Two-step ordering with the client: this asset must be live and
verified (the deploy's verify step compares the served pair against
what it just signed) **before**
`ModerationTrust.enforceManifestSignatures` is flipped on in onym-ios
— under enforcement, a 404 or a stale signature rejects the manifest
and blocks consent outright.

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
  `AUTHORITY_ADMIN_TOKEN`, and optionally `AUTHORITY_MODERATOR_TOKEN`
  and `MODERATION_AUDIT_TOKEN`.
- **Variables** (all optional; defaults in the workflow):
  `DOMAIN`, `NOSTR_HOST`, `BLOSSOM_HOST`, `RELAYER_HOST`,
  `MODERATION_HOST`, `AUTHORITY_HOST`, `MODERATION_DEVICECHECK_ENV`,
  `MODERATION_ENFORCE_SIGNATURES`, `AUTHORITY_INTERFACE_KEY`,
  `MODERATION_INTERFACE_KEY_EPOCHS`, `CADDY_EMAIL`, `DO_REGION`,
  `DO_DROPLET_SIZE`, and `DROPLET_ID`.

`AUTHORITY_INTERFACE_KEY` is a variable and not a secret because it is
a *public* key, and because it does not exist until the interface has
booted once. Read `interfaceKey` from the interface's `/health` —
see the two-pass first deploy above.

## Rotating an authority's countersigning key

The interface derives a **separate** countersigning key per authority,
from `MODERATION_INTERFACE_SIGNING_SEED` plus a per-authority epoch in
`MODERATION_INTERFACE_KEY_EPOCHS`. Empty means everyone is on epoch 0,
which is the seed used directly — the un-rotated state, and the one
this deployment is in.

Bumping one authority's epoch rotates only that relationship. Every
other authority's mandates are untouched, which is the whole reason the
keys are per-authority: rotating a single shared key would invalidate
every countersignature ever issued, to everyone, at once.

**This is about rotation, not containment.** All the derived keys live
in the same process as the root, so this does not reduce what a
compromise of the interface host costs. What it buys is the ability to
burn one relationship — a key you no longer trust, or an authority you
are de-listing.

Both sides live in this stack, so the sequence is visible in one place.
`AUTHORITY_INTERFACE_KEY` accepts a **comma-separated list**, and that
is what makes the rotation gapless — the authority verifies against any
listed key while the cutover happens:

1. Derive the next key without deploying it. Bump the epoch in a
   scratch environment and read `rotatedInterfaceKeys` from the
   interface's `/health`, or compute it offline.
2. **Add** it to `AUTHORITY_INTERFACE_KEY` beside the current one and
   deploy. Both keys now verify; nothing has changed for users.
3. Set the authority's entry in `MODERATION_INTERFACE_KEY_EPOCHS` and
   deploy. The interface signs with the new key from here on, and the
   countersignatures it issued before still verify because the
   authority still lists the old key.
4. Remove the old key from `AUTHORITY_INTERFACE_KEY` and deploy.

Step 4 is the only irreversible one, and it is the point: it is what
stops the old key working. Everything before it can be walked back.

Doing steps 2 and 3 in the other order, or skipping the list and
swapping a single value, means every registration for that authority is
refused until both sides agree — there is no ordering of a single-key
swap that avoids it.

An authority you have never rotated needs no entry in either place. And
note the failure mode of getting the component id wrong: it parses
fine, silently leaves that authority on epoch 0, and shows up as a
*signature* error rather than a configuration one. The interface names
every configured id in its boot log beside the key it produced —
compare it against what the mandates actually carry.

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

The human moderation queue is at `https://$AUTHORITY_HOST/admin`, protected by
`AUTHORITY_ADMIN_TOKEN`. With autonomous triage off in this stack, its
deadline-ordered first queue is every open case awaiting a decision;
the second is appeals and new-holder claims. The Authority refuses to
start without this human route, and deploy catches an empty token
before building or touching the droplet.

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
