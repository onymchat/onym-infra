# Remote state in a DigitalOcean Space (S3-compatible).
#
# One-time setup (the Space is NOT created by this configuration —
# backends cannot manage their own bucket):
#
#   1. Create the Space (billed resource, so it is a deliberate step):
#        doctl spaces create onym-infra-tfstate --region ams3
#      or in the control panel: Spaces -> Create -> region ams3.
#
#   2. Create a Spaces access key (NOT the same as the DO API token):
#        control panel -> API -> Spaces Keys -> Generate New Key
#      and export it under the AWS names the S3 backend expects:
#        export AWS_ACCESS_KEY_ID=<spaces access key>
#        export AWS_SECRET_ACCESS_KEY=<spaces secret key>
#
#   3. `tofu init` from this directory.
#
# The skip_* flags are required: Spaces speaks the S3 API but is not
# AWS, so STS credential validation, account-id lookup, the EC2
# metadata probe, region validation against the AWS region list, and
# AWS-style payload checksums must all be disabled.
#
# State will contain resource attributes (droplet ID/IP, DNS record
# ids, zone id) but NO secrets by design — see github.tf for the rule
# that keeps it that way. Treat the Space as private regardless.

terraform {
  backend "s3" {
    # PLACEHOLDER-SPACES-BUCKET: name of the Space created in step 1.
    # Lookup (if it already exists): doctl spaces list
    bucket = "onym-infra-tfstate"

    key = "onym-infra/terraform.tfstate"

    # Ignored by Spaces but the backend requires a syntactically valid
    # AWS region; the real region lives in the endpoint below.
    region = "us-east-1"

    endpoints = {
      s3 = "https://ams3.digitaloceanspaces.com"
    }

    skip_credentials_validation = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_s3_checksum            = true

    # STATE IS NOT LOCKED. OpenTofu's S3-native lockfile (1.10+,
    # `use_lockfile = true`) depends on conditional writes
    # (If-None-Match), which DigitalOcean Spaces does not document
    # supporting — an unverifiable lock is worse than an honest
    # absence, so this is explicitly false. Serialization comes ONLY
    # from the CI concurrency group `tofu-state` shared by every job
    # that reads or writes state (.github/workflows/tofu.yml). Do not
    # run local applies while CI might be applying. If Spaces ever
    # documents conditional-write support, flip this to true.
    use_lockfile = false
  }
}
