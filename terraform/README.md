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
| DO cloud firewall 22/80/443 + 443/udp | on-box `ufw` (cloud-init) stays as-is |
| A records: nostr, blossom, relayer, moderation, authority, discovery | other zone records (bank, n8n, MX, TXT…) untouched |
| `production` environments on onym-discovery + onym-relayer (reviewers) | secret **values** — never IaC, see below |

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

   - **6 imports** — the droplet and the 5 existing A records — each
     with **no changes** to the imported resource;
   - **4 creates**, all verified absent from live infra on 2026-08-14:
     the DO firewall, the `discovery.onym.app` A record, and the two
     `production` environments;
   - **zero changed, zero destroyed**.

   Anything else means reality moved since the ids were resolved: stop
   and re-run the lookup commands in `imports.tf`, do not apply. An
   in-place change on an imported record usually means a field here no
   longer byte-matches live (e.g. TTL — deploy.sh writes 120, and
   `dns_ttl` matches it on purpose).

5. **Apply**, then plan again — the second plan must be empty:

   ```bash
   tofu apply
   tofu plan   # -> "No changes."
   ```

6. **Wire up CI** (`.github/workflows/tofu.yml`): add repo secrets
   `SPACES_ACCESS_KEY_ID`, `SPACES_SECRET_ACCESS_KEY`,
   `TF_GITHUB_TOKEN` (org secrets `DO_API_KEY` / `CF_API_TOKEN` are
   reused as-is), and protect the `production` environment on
   **this** repo with required reviewers **before** the first push to
   main — GitHub auto-creates it unprotected otherwise.

## Day 2

- **PRs** touching `terraform/` get fmt-check + validate always, and a
  full `tofu plan` posted as a PR comment when secrets are available
  (fork PRs get a validate-only note).
- **Applies** happen only from main, and only after a human approves
  the `production` environment gate.
- **Drift**: every Monday CI runs `tofu plan -detailed-exitcode`; a
  non-empty diff opens (or appends to) an issue titled
  "tofu drift: …" with the plan attached. deploy.sh upserting the same
  A-record values is not drift — both writers agree on every field.
- `deploy.sh` keeps working unchanged; it adopts the droplet by name
  and never resizes or recreates it, and `prevent_destroy` +
  `ignore_changes` on the droplet keep the two owners from fighting.
