# terraform/ — the infrastructure layer, as OpenTofu

This directory describes the infrastructure **around** the compose
stack — the droplet, its cloud firewall, the Cloudflare A records, and
the GitHub `production` environments — as [OpenTofu](https://opentofu.org)
configuration. What runs **on** the droplet stays owned by
`deploy/digitalocean/deploy.sh`, exactly as before; nothing here
replaces it.

## Why OpenTofu and not Terraform

OpenTofu is the open-source (MPL-2.0) fork of Terraform under the Linux
Foundation; HashiCorp relicensed Terraform itself to the BUSL in 2023.
This repo's other tooling is open source and its services are contracts
other operators are meant to be able to run — the IaC layer follows the
same rule. Provider versions in `versions.tf` are pinned exactly and
resolved from `registry.opentofu.org`. Use the `tofu` binary
(`brew install opentofu`); the CI workflow does the same and nothing
here is tested against the `terraform` binary.

## What is managed vs. not

| Managed here | Owner elsewhere |
|---|---|
| droplet `onym-infra` (exists, size, region) | on-box state: `deploy.sh` (docker, compose, secrets, manifest) |
| DO cloud firewall 22/80/443/icmp + 443/udp | on-box `ufw` (cloud-init) stays as-is |
| A records: nostr, blossom, relayer, moderation, authority | other zone records (bank, n8n, MX, TXT…) untouched |
| `discovery.onym.app` A record — **only after adoption**, see below | **onym-discovery's deploy creates it** (`ci-deploy.sh`, DNS-last) |
| `production` environments on onym-discovery + onym-relayer (reviewers) | secret **values** — never IaC, see below |

## Who owns `discovery.onym.app`

Nothing in this repo serves that name: the `Caddyfile` has no
discovery vhost and `deploy.sh`'s `HOSTS` list stops at the five
existing names. Creating the A record from here first would point
clients at a Caddy with no matching site and no certificate — a TLS
handshake failure, not a 404.

So the record's **lifecycle is owned by onymchat/onym-discovery**: its
deploy workflow installs the Caddy vhost on this droplet,
health-checks it, and creates the A record **last**. In this
configuration the record is gated behind `discovery_deployed`
(default `false`, so it is a no-op). After the first onym-discovery
genesis deploy has created the record, adopt it here — flip the
variable **and** import (commands in `dns.tf`) — and from then on
OpenTofu is the system of record, exactly as for the other five
records: onym-discovery's per-deploy upsert writes the same values and
creates no drift. Do not flip the variable without importing: that
would try to create a second A record.

## State is NOT locked

The S3-compatible backend has no working lock: OpenTofu 1.10+'s
`use_lockfile` needs S3 conditional writes, which DigitalOcean Spaces
does not document supporting, so `backend.tf` sets it to `false`
explicitly rather than trusting a lock that may silently not hold.
**The only serialization is the CI concurrency group `tofu-state`**,
which every state-touching job (PR plan, apply, drift) joins. The
corollary: never run `tofu apply` (or a state-refreshing plan) locally
while CI could be applying — check the Actions tab first.

One queue caveat: GitHub holds at most **one pending run per
concurrency group** — a third arrival cancels the queued second, it
does not line up behind it. So a missing weekly drift run may mean it
was cancelled by busier traffic, not that there was no drift; check
the Actions tab for a cancelled `drift` run before concluding
anything.

## The secrets-never-in-state rule

OpenTofu state stores every attribute in plaintext — `sensitive` only
redacts CLI output. Therefore **no resource in this directory may
carry a secret value**: no `github_actions_secret`, no seeds, no
tokens. Secrets are declared (as comments, in `github.tf`) and set out
of band with `gh secret set` or the Settings UI. Provider credentials
are environment variables only. If a change would put a secret value
into a plan or state file, the change is wrong.

## Bootstrap runbook (import-first)

Everything that already exists is **imported**, not recreated. Live
ids were resolved read-only on 2026-08-14 and are baked into
`imports.tf` and `variables.tf` — re-verify them with the lookup
command next to each one if you are bootstrapping much later.

1. **Create the state Space** (billed, hence manual):

   ```bash
   doctl spaces create onym-infra-tfstate --region ams3
   ```

   If you pick another name, change `bucket` in `backend.tf`
   (PLACEHOLDER-SPACES-BUCKET marks the spot).

2. **Credentials**, environment variables only:

   ```bash
   export DIGITALOCEAN_TOKEN=...     # DO API token (same value as DO_API_KEY)
   export CLOUDFLARE_API_TOKEN=...   # DNS:Edit on onym.app (same value as CF_API_TOKEN)
   export GITHUB_TOKEN=...           # PAT with admin on onym-discovery, onym-relayer, onym-infra
   export AWS_ACCESS_KEY_ID=...      # Spaces access key   (control panel -> API -> Spaces Keys)
   export AWS_SECRET_ACCESS_KEY=...  # Spaces secret key
   ```

3. **Init**:

   ```bash
   cd terraform && tofu init
   ```

4. **Plan — this is the acceptance bar**:

   ```bash
   tofu plan
   ```

   The first plan must show **exactly**:

   - **9 imports** — the droplet, the 5 pre-existing A records, the
     discovery record (created by the 2026-08-15 genesis deploy), and
     the two production environments (created during the same rollout;
     Tofu reconciles reviewer/branch-policy settings in place) — each
     with **no changes** to the imported resource;
   - **1 create** — the DO firewall, still verified absent (imports may
     show settings drift on the environments as in-place *changes*;
     review those diffs, they are Tofu asserting the gate config);
   - **zero destroyed** (changes only on the two imported environments
     if their hand-created settings differ from github.tf).

   Anything else means reality moved since the ids were resolved: stop
   and re-run the lookup commands in `imports.tf`, do not apply. An
   in-place change on an imported record usually means a field here no
   longer byte-matches live (e.g. TTL — deploy.sh writes 120, and
   `dns_ttl` matches it on purpose).

   Know what the two consequential creates DO before applying:

   - **The firewall create is not a no-op.** Attaching a DO cloud
     firewall default-denies every inbound port not listed. The rules
     cover 22/80/443 tcp, 443/udp, and inbound ICMP (added
     deliberately — without it, ping and inbound path-MTU discovery to
     the box would stop working after apply). Anything else that was
     implicitly reachable stops being reachable.
   - **The `production` environments change other repos' deploys.**
     See the operator checklist below.

   Also note 443/udp opens QUIC only at the cloud layer — on-box ufw
   still blocks it (`droplet.tf` has the follow-up).

5. **Notify the onym-discovery and onym-relayer owners** before the
   apply: creating the `production` environments with required
   reviewers means their workflows (onym-discovery `deploy.yml`,
   onym-relayer `sign-manifest.yml`) **start blocking on a human
   approval from the moment this applies**. That gate is the point,
   but it must not surprise the people whose deploys it stops.

   Also on the operator checklist: the environments restrict deploys
   to **protected branches** (`deployment_branch_policy` in
   `github.tf`), so **`main` must actually be protected in
   onym-discovery and onym-relayer** before their next deploy — an
   unprotected `main` fails the branch policy check and the deploy
   never starts. One-liner per repo:
   `gh api -X PUT repos/onymchat/<repo>/branches/main/protection ...`
   or Settings → Branches.

6. **Apply**, then plan again — the second plan must be empty:

   ```bash
   tofu apply
   tofu plan   # -> "No changes."
   ```

7. **Wire up CI** (`.github/workflows/tofu.yml`): add repo secrets
   `SPACES_ACCESS_KEY_ID`, `SPACES_SECRET_ACCESS_KEY`,
   `TF_GITHUB_TOKEN` (org secrets `DO_API_KEY` / `CF_API_TOKEN` are
   reused as-is), and protect the `production` environment on
   **this** repo with required reviewers **before** the first push to
   main — GitHub auto-creates it unprotected otherwise.

## Day 2

- **PRs** touching `terraform/` get fmt-check + validate always, and a
  full `tofu plan` posted as a PR comment for same-repo PRs only —
  fork PRs are excluded by explicit condition, both because the plan
  comment is an infra inventory (droplet IP, zone/record ids) and
  because the unlocked state must not be touched on behalf of an
  untrusted head ref.
- **Applies** happen only from main, in two stages: an ungated job
  produces and saves the plan (readable in the step summary), then the
  `production`-gated job applies **that exact saved plan** — the
  approver reviews the real diff, and a stale plan (state moved while
  approval waited) errors on the state-serial mismatch instead of
  applying.
- **Drift**: every Monday CI runs `tofu plan -detailed-exitcode`; a
  non-empty diff opens (or appends to) an issue titled
  "tofu drift: …" with the plan attached. deploy.sh upserting the same
  A-record values is not drift — both writers agree on every field.
- `deploy.sh` keeps working unchanged; it adopts the droplet by name
  and never resizes or recreates it, and `prevent_destroy` +
  `ignore_changes` on the droplet keep the two owners from fighting.
