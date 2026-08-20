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
| **backup** | `backup.onym.app` | device-backup retention operator — holds sealed snapshots and cannot read them (git submodule → [`onym-backup`](https://github.com/onymchat/onym-backup)) |
| *(static)* | `discovery.onym.app` | Onym Discovery provider — a signed static tree under `/var/www/discovery`, served by Caddy's `file_server`. No container; the artifacts are published by [`onym-discovery`](https://github.com/onymchat/onym-discovery)'s Deploy workflow (see [The discovery static seat](#the-discovery-static-seat)) |

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
- `docker` with `buildx`, **only** if you set `DOCR_NAME` (see
  [Container images](#container-images))
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
cp backup.env.example backup.env            # BACKUP_SIGNING_SEED (required) — read what it says about losing it

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
  re-run `deploy.sh` (rebuilds that one image).
- **Moderation code:** same shape — `git -C moderation pull`, commit,
  re-run `deploy.sh`.
- **The authority manifest and policy documents:** the reference
  template and policy documents change by bumping the submodule. The
  deployed manifest is materialized from that template with the
  deployment's operator key and `AUTHORITY_HOST`. Changing any of those
  bytes after consent creates a new manifest hash, so existing mandates
  remain bound to the old terms and fresh consent is required.

## Container images

Set `DOCR_NAME` and the droplet stops compiling anything. The three
first-party images — relayer, moderation interface, moderation authority
— are built wherever `deploy.sh` runs, pushed to the DigitalOcean
container registry, and pulled on the far end. Leave it empty and the old
behaviour is unchanged: sources are rsynced and built in place.

```sh
doctl registry create onym --region ams3   # once; it is a billed resource
echo 'DOCR_NAME=onym' >> .env
./deploy/digitalocean/deploy.sh
```

In CI it is the `DOCR_NAME` repository **variable**. It authenticates
with `DO_API_KEY`, which is already required, so there is no new secret
to hold. Note that DigitalOcean allows exactly one registry per account —
`DOCR_NAME` must be its name, and a mismatch is a hard error rather than
a second registry.

**Tags are the submodule commit** (`…/relayer:a1b2c3d4e5f6`). Two things
follow. A submodule that has not moved is already in the registry, so
`deploy.sh` skips its build entirely — a config-only deploy builds
nothing at all. And a deployed image can be traced to the exact commit it
came from without consulting the deploy log.

A context with uncommitted changes is tagged `-dirty` and is **always**
rebuilt and repushed. The SHA has stopped describing what would be built,
and silently shipping the last clean image is the wrong way to lose
someone's edit. `moderation/apple` and `moderation/authority` share a
submodule, so dirtiness is scoped per directory — editing one does not
force a rebuild of the other.

Images are built `--platform linux/amd64` through a `docker-container`
buildx builder. Both are load-bearing on an Apple silicon laptop: without
them you push an arm64 image that deploys cleanly and then dies with
`exec format error` on a droplet you cannot easily see.

The droplet gets a **read-only** registry credential, refreshed on every
deploy with a 30-day expiry (`DOCR_CRED_TTL`). It pulls; it can never
push an image back that the next deploy would trust. An abandoned box
loses access by going stale rather than by anyone remembering to revoke
it. Since Docker's `restart: unless-stopped` restarts containers from
local images, an expired credential blocks the next deploy — never a
reboot.

One rough edge, for local builds only. The build context is uploaded to
the builder, and `rsync`'s `--exclude '*/target'` does not apply to it —
so the exclusion has to live in the context. `relayer/` ships a
`.dockerignore`; `moderation/apple` and `moderation/authority` do not,
and a checkout that has been `cargo build`-ed locally carries hundreds of
megabytes of `target/` into the context. `deploy.sh` warns when it sees
this. The fix belongs upstream in `onym-moderation`; CI checks out fresh
and is unaffected.

Deterministic tags accumulate. The registry's storage is billed, so
prune periodically:

```sh
doctl registry repository list
doctl registry garbage-collection start
```

### Why this exists

Building on the droplet is what makes this deployment structurally
single-box: three Rust builds on a 2 GB machine, serialized with
`COMPOSE_PARALLEL_LIMIT=1` so they do not OOM. Nothing here becomes a
second machine, or an autoscaled anything, until images are built once
and pulled many times. This is that change and nothing more — the stack
is still one droplet.

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
to a staging name, finalized, signed **inside the authority image**
(the seed never leaves `authority.env`, same as
`derive-operator-key`), and only then is the live pair touched — old
signature retired, new manifest moved into place, new signature
written last. A finalize or signing failure leaves the previous
manifest+signature pair fully intact; any later interruption degrades
to a missing signature (404 → soft-verify). At no instant can the
published signature cover different bytes than the published manifest.

The finalize step (`finalize-manifest`, same image, same seed) is what
makes the manifest pass the clients' **discovery-seat
destination-manifest review**: it injects the top-level `name`
(`AUTHORITY_MANIFEST_NAME`, default "Onym Authority") and `endpoints`
(from `AUTHORITY_PUBLIC_URL`, derived from `AUTHORITY_HOST` in
compose) that the catalog adapters read, and embeds a second,
**embedded** `signature` — the same operator key over the discovery
profile's canonical signing bytes (the document minus `signature`,
compact, keys sorted). The detached `.sig` above still covers the
final file's exact bytes, embedded signature included, which is why
finalizing happens first. Both knobs have defaults; no new secret or
required variable.

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

## The discovery static seat

`https://$DISCOVERY_HOST/` (default `discovery.onym.app`) is a static,
signed directory tree — the Onym Discovery provider: `manifest.json`
(+ detached `.sig`), the chain-linked catalog snapshots under
`catalogs/`, the courier/blossom seat manifests under `manifests/`,
and the policy/privacy documents. Two repos compose to serve it, with
a deliberate split:

- **This repo owns the vhost only**: the `{$DISCOVERY_HOST}` block in
  the `Caddyfile`, the `/var/www/discovery:/srv/discovery:ro` mount in
  `docker-compose.yml`, the Cloudflare A record (via the `HOSTS`
  array), and the `mkdir -p /var/www/discovery` in `deploy.sh`.
  Nothing here ever writes *into* the web root, and the root lives
  outside `/opt/onym-infra` so this repo's rsync `--delete` can never
  sweep a published, signed chain away.
- **[`onym-discovery`](https://github.com/onymchat/onym-discovery)
  owns the artifacts**: its Deploy workflow
  (`deploy/onym/ci-assemble.sh` + `ci-deploy.sh`) signs, chains the
  snapshot onto the previously *published* bytes, verifies everything
  exactly as a client would, and rsyncs the tree to
  `/var/www/discovery` on this droplet (never with `--delete` —
  retention siblings stay live until they expire).

An **empty web root is a valid degraded state**: this stack deploys
green, the vhost gets its certificate, and every path answers 404
until the first discovery publish lands. Neither deploy depends on the
other's ordering — the discovery workflow carries a stopgap
(`ensure-caddy-vhost.sh`) that installed the vhost via a compose
override before this repo grew the native block above; it detects the
native `{$DISCOVERY_HOST}` site block and steps aside, so it is now a
no-op that simply verifies the vhost exists.

**Coupling to the authority manifest.** The discovery snapshot pins
the sha256 of the exact `https://$AUTHORITY_HOST/manifest.json` bytes
that were reviewed (committed as `deploy/onym/reviewed/onym-authority.json`
in onym-discovery). Any deploy from this repo that changes those bytes
— a manifest edit, the materializer adding fields, an operator-key
change — breaks that pin for clients until onym-discovery re-fetches,
re-reviews, commits the new bytes, and **publishes a new snapshot
sequence**. The same holds for `relayer.onym.app/manifest.json`. After
such a deploy, run the onym-discovery publish runbook (its README:
"Each publish").

## The device-backup seat

`backup.onym.app` runs [`onym-backup`](https://github.com/onymchat/onym-backup),
the retention operator for the device-backup seat. It holds sealed
snapshots and **cannot read them**: every snapshot arrives encrypted
under a key derived from the holder's BIP39 recovery phrase, and no code
path in the service can open one. That is the absence of a capability
rather than a promise about conduct, which is why it can sit on this box
without widening what the box knows about anyone.

It runs in **free mode**: `BACKUP_ENTITLEMENT_ISSUERS` is unset, so the
operator never returns `402` and never consults an entitlement. Nothing
issues a `SeatEntitlement` yet, so a charging operator would refuse
every upload with a refusal no client could clear. Turning it on later
needs the issuers, a revocation URL and an offer id together — the
operator refuses to boot with issuers and no revocation URL (a refunded
entitlement would keep working until it expired) or with no offers (a
`402` naming no offer tells a client to buy something without saying
what).

**`BACKUP_SIGNING_SEED` is not like the other seeds.** The moderation
seeds sign verdicts, and losing one invalidates future signatures.
This one is pinned by every client that consents to the operator: the
manifest they pinned carries the public key derived from it, every
retained snapshot pins a terms document signed with it, and every
erasure receipt a holder holds verifies against it. Regenerate it and
the operator becomes, to everyone already enrolled, a different
operator wearing the same hostname — and there is no route that repairs
that, because reassigning a snapshot's holder is precisely the
capability this seat is built not to have. Back it up out of band.

**The blob volume is the only copy of anyone's backup**, and nothing
here backs it up. That gap has to close before anyone who is not a
tester relies on this. See "Capacity" for why it is a separate volume.

**Being listed is a separate step.** A client can only reach an
operator it has a pinned consent record for, and those come from a
signed discovery catalog entry — so deploying this makes the operator
reachable, not discoverable. The entry goes in the `onym-services`
catalog published by the onym-discovery repo, whose provider manifest
must also list `storage.backup` in its `seatTypes` or clients filter
the catalog and never see it.

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
  and `MODERATION_AUDIT_TOKEN`. For the Android interface:
  `MODERATION_ANDROID_INTERFACE_SIGNING_SEED` (a DIFFERENT seed from
  the Apple one), `MODERATION_ANDROID_AUTHORITY_TOKEN` (written into
  the authority's `AUTHORITY_INTERFACE_ROUTES` — one secret, two
  files), and optionally `MODERATION_PLAY_SA_KEY_JSON` (absent =
  degraded checkRequired until Google grants device-recall access)
  and `MODERATION_ANDROID_AUDIT_TOKEN`.
- **Variables** (all optional; defaults in the workflow):
  `DOMAIN`, `NOSTR_HOST`, `BLOSSOM_HOST`, `RELAYER_HOST`,
  `MODERATION_HOST`, `MODERATION_ANDROID_HOST`, `AUTHORITY_HOST`,
  `DISCOVERY_HOST`,
  `MODERATION_DEVICECHECK_ENV`, `MODERATION_ENFORCE_SIGNATURES`,
  `AUTHORITY_INTERFACE_KEY`, `AUTHORITY_INTERFACE_KEYS_BY_COMPONENT`,
  `MODERATION_INTERFACE_KEY_EPOCHS`,
  `MODERATION_ANDROID_INTERFACE_KEY_EPOCHS`,
  `MODERATION_PLAY_PACKAGE_NAME`,
  `MODERATION_PLAY_CERT_SHA256_DIGESTS` (base64url-nopad, Google's
  token spelling — not the console's colon-hex), `CADDY_EMAIL`,
  `DO_REGION`, `DO_DROPLET_SIZE`, and `DROPLET_ID`.

`AUTHORITY_INTERFACE_KEY` is a variable and not a secret because it is
a *public* key, and because it does not exist until the interface has
booted once. Read `interfaceKey` from the interface's `/health` —
see the two-pass first deploy above. The Android interface has the
same two-pass shape through
`AUTHORITY_INTERFACE_KEYS_BY_COMPONENT=onym:component:onym-android=<key>`,
read from `https://<MODERATION_ANDROID_HOST>/health` — and it is
scoped per component on purpose: with two interface backends, a flat
key union would let one backend's key witness mandates naming the
other.

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

## Capacity

The droplet is `s-2vcpu-4gb` (raised from `s-1vcpu-2gb`, which was
already at its ceiling — cloud-init adds a 2G swapfile precisely
because the relayer build OOMed on it).

**Changing `DO_DROPLET_SIZE` does not resize the running box.**
`deploy.sh` adopts an existing droplet by name and never resizes it, so
the new default only applies to a droplet being created — a deploy will
not recreate or resize anything.

Growing the live box is a **resize, not a recreate**: same droplet ID,
same public IP (the Cloudflare records stay valid), same volumes, data
intact. It needs a power-off, so it stays deliberately manual — the
`doctl` sequence is in the comment above `DO_DROPLET_SIZE` in
`deploy/digitalocean/deploy.sh`. That sequence omits `--resize-disk` on
purpose: a CPU/RAM-only resize is reversible, a disk resize is
permanent and forecloses ever scaling back down. Disk is not the
constraint here, so the 50 GB carries over unchanged.

Because the limits below are budgeted for 4G, **resize before or with
the deploy that lands them** — 3264M of caps on a 2G box will start
killing containers.

Every service now carries a `mem_limit` (3264M capped of 4G, leaving
~832M for the host and page cache — the backup operator's 256M came
out of that headroom, since it streams chunks rather than buffering
them and holds no large working set). The point is blast radius, not
efficiency: with no limits, an unbounded relay response lets the
kernel's OOM killer choose the victim, and it may well choose the
authority — silently undoing the authority/interface separation of
powers several layers below where the design reasons about it. A
killed relay that restarts is an acceptable outcome; a killed
authority is not.

What actually constrains this box, in the order it will bite:

1. **RAM during replay.** A client REQ with no `limit` buffers its
   whole result set, and strfry 1.1.1 has no outbound buffer cap —
   `maxPendingOutboundBytes` exists only on upstream master, in no
   released tag. Until the client paginates or uses negentropy, the
   relay's `mem_limit` *is* the cap.
2. **CPU.** `ingester` runs secp256k1 verification on every event and
   `reqMonitor` matches each new event against every open subscription,
   so both scale with connections rather than cores. `numThreads` is
   sized to the 2 vCPUs rather than to strfry's 3/3/3/2 defaults.
3. **Disk, on the root filesystem.** Still not a constraint, and the
   reasoning is unchanged: ~35k events at ~1–2 KB each is well under
   100 MB, and even a *sustained* 800 events/day (the 2026-08-16
   incident peak, as an everyday rate) is ~450 MB/yr against 50 GB.
   Relay retention should never be argued from disk here — see below
   for what it is actually for.
4. **Disk, on the backup volume.** This one is a constraint, and it is
   new. Sealed snapshots are the only thing on this box measured in
   gigabytes, and the operator's own defaults would allow 6 GiB per
   holder (2 GiB x 3). They are held at 256 MiB x 2 here and live on a
   **separate block volume** at `/mnt/onym-backup-blobs`, bind-mounted
   into the container.

   The separation is the point. On the root filesystem those bytes
   would share 50 GB with strfry's database and both moderation
   stores, and a full disk there is not "backup is unavailable" — it is
   the authority unable to record a verdict and the relay unable to
   accept an event. That is the blast-radius argument the `mem_limit`s
   make, applied to the one resource that had no limit.

   `deploy.sh` refuses to deploy if that path is not a mountpoint. It
   does **not** create or format the volume: attaching one is cheap to
   automate, formatting is one-way, and a script that runs `mkfs`
   against whatever is at that path will eventually destroy someone's
   snapshots. The commands are in the failure message, and the
   destructive step stays in a human's hands — the same posture as the
   droplet resize above.

The strfry image is **pinned** (`dockurr/strfry:1.1.1`). It was
`:latest`, which had drifted: the running container was 1.1.0 while
`latest` had moved to 1.1.1, so the next pull would have changed relay
versions during whatever deploy happened to trigger it.

## Relay retention

**The relay applies no blanket TTL. Retention is decided per event by
the client, with a NIP-40 `expiration` tag.**

The reason for that split is the client's restore path. A device that
loses its local store recovers by replaying `nostr.onym.app` with an
unlimited REQ — the relay is the only durable copy of a conversation
(this is also why `maxFilterLimit` is 100000; see commit `2bab420`). A
server-side cutoff would therefore cap every future restore at the
cutoff, and users would discover that only at the moment they needed
the history. Per-event expiration puts the same lifetime decision in
the client, where it is a product feature — disappearing messages —
that the sender chooses knowingly, instead of a silent infra policy.

**strfry needs no configuration for this and never did.** NIP-40 is
enforced unconditionally in the build we run:

- the `expiration` tag is parsed at ingest and indexed
  (`src/events.cpp`),
- a cron sweeps the expiration index every ~9s and **hard-deletes**
  expired events — this is not query-time hiding, the bytes leave LMDB
  (`src/apps/relay/RelayCron.cpp`),
- an event whose `expiration` is already in the past is **rejected** at
  ingest with `event expired`.

So there is nothing to turn on here. Everything below is the client
contract, and getting it wrong fails silently — events simply live
forever and nobody notices.

**The tag must go on the outer `kind:1059` giftwrap.** An `expiration`
inside the sealed rumor is encrypted, so the relay cannot see it and
will not act on it. This is the mistake to watch for. The tradeoff is
that the expiry timestamp is public metadata on the wrapper: the relay
(and anyone who can read the wrapper) learns *when* a message dies,
though not what it is or who wrote it. That is judged acceptable; the
alternative leaks nothing but also expires nothing.

Other edges worth knowing:

- Only the **first** `expiration` tag on an event is honoured; later
  ones are ignored, not merged or minimised.
- A value below `100` is rejected outright as invalid.
- Expiry is **not** relative to `created_at` — it is an absolute unix
  timestamp, so the client computes `now + ttl` at send time. Note that
  NIP-59 giftwraps randomise `created_at` up to ~2 days into the past;
  do not derive the expiration from it.
- Once swept, an event **cannot be re-uploaded** — ingest rejects it as
  expired. Expiry is final, including against a client trying to
  restore from its own archive.
- Retention is per event, so old messages sent before the client starts
  stamping tags stay forever. Changing the client's default TTL only
  affects new sends; it is not retroactive.

Since expiry is irreversible and the relay is the backup of record, the
sane rollout is to stamp a generous TTL first and shorten it once the
client keeps a durable local archive with an export path — at which
point the relay stops being the only copy and a short TTL becomes
cheap.

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
