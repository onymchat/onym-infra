# ============================================================================
# SECRETS ARE NEVER MANAGED HERE — READ THIS BEFORE ADDING A RESOURCE
# ============================================================================
# OpenTofu state stores every resource attribute IN PLAINTEXT, including
# attributes marked "sensitive" (that flag only redacts CLI output). A
# github_actions_secret / github_actions_environment_secret resource
# would therefore copy the secret's value into the state Space, turning
# our signing seeds into a bucket-read away from compromise. So:
#
#   - NO github_actions_secret resources, ever, for anything.
#   - Secret VALUES are set by a human with `gh secret set` or the repo
#     Settings UI, and live only in GitHub's encrypted store.
#   - This file may DECLARE which secrets an environment expects, as
#     comments only (below), so the inventory is reviewable without the
#     values ever touching state.
#
# Secrets each repo's "production" environment expects (values set out
# of band — `gh secret set <NAME> --repo onymchat/<repo> --env production`):
#
#   onym-discovery (deploy.yml):
#     DO_API_KEY                 DigitalOcean API token
#     SSH_PRIVATE_KEY            key the droplet trusts
#     + the signing seeds its deploy gates behind this environment
#
#   onym-relayer (sign-manifest.yml):
#     the manifest signing seed/material that workflow gates behind
#     this environment
#
# (Check each workflow's header comment for the authoritative list —
# they document their own secrets and this comment is a pointer, not a
# second source of truth.)
# ============================================================================

# The "production" environment on the two repos whose workflows already
# reference it (onym-discovery deploy.yml, onym-relayer
# sign-manifest.yml). Verified 2026-08-14 via
# `gh api repos/onymchat/<repo>/environments`: NEITHER repo has the
# environment yet — GitHub would auto-create it UNPROTECTED on first
# dispatch, which onym-discovery's own workflow warns about. Creating
# them here, with required reviewers, before any dispatch, is the
# point of this file. Both are genuine CREATEs (nothing to import).

locals {
  production_environment_repos = [
    "onym-discovery",
    "onym-relayer",
  ]
}

resource "github_repository_environment" "production" {
  for_each = toset(local.production_environment_repos)

  repository  = each.key
  environment = "production"

  # Deploys wait for a human approval, not for a timer.
  wait_timer = 0

  # Both knobs below are set EXPLICITLY because their defaults quietly
  # hollow out the gate: `can_admins_bypass` defaults to true (an admin
  # can skip review entirely) and `prevent_self_review` defaults to
  # false (the sole reviewer can approve their own deploy). The gate
  # must enforce what it records, so admin bypass is off.
  can_admins_bypass = false

  # ACCEPTED RESIDUAL RISK, on purpose: with exactly one human in the
  # org, `prevent_self_review = true` would deadlock every deploy until
  # a second reviewer (or a team/bot arrangement) exists. So this stays
  # false — explicitly, not by default — meaning the reviewer can
  # approve a deploy they themselves triggered. Flip this single line
  # to true the moment there is a second reviewer.
  prevent_self_review = false

  reviewers {
    users = var.production_reviewer_user_ids
    teams = var.production_reviewer_team_ids
  }

  # Production deploys only from protected branches — otherwise ANY
  # branch or tag in these repos could target `production` and reach
  # its secrets after one approval. Corollary for operators: `main`
  # must actually BE protected in onym-discovery and onym-relayer, or
  # their deploys fail this policy check (see the README checklist).
  deployment_branch_policy {
    protected_branches     = true
    custom_branch_policies = false
  }
}

# Optional: branch protection for main on onym-infra itself. Default
# OFF (var.manage_branch_protection = false) — flip it only when the
# team decides IaC should own this knob, and review the settings below
# first; they are a starting point, not a decree.
resource "github_branch_protection" "onym_infra_main" {
  count = var.manage_branch_protection ? 1 : 0

  repository_id = "onym-infra"
  pattern       = "main"

  required_pull_request_reviews {
    required_approving_review_count = 1
  }

  # PLACEHOLDER-STATUS-CHECKS: contexts to require once agreed, e.g.
  # the fmt/validate job from .github/workflows/tofu.yml.
  # Lookup for names of recent check runs:
  #   gh api repos/onymchat/onym-infra/commits/main/check-runs --jq '.check_runs[].name'
  # required_status_checks {
  #   strict   = true
  #   contexts = ["tofu / fmt-and-validate"]
  # }

  enforce_admins = false
}
