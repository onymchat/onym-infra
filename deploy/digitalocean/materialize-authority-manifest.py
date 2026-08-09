#!/usr/bin/env python3
"""Materialize the deployment manifest from the upstream reference template."""

import json
import os
import re
import sys
import tempfile
from pathlib import Path


def fail(message: str) -> None:
    raise SystemExit(message)


if len(sys.argv) != 5:
    fail("usage: materialize-authority-manifest.py SOURCE TARGET OPERATOR_KEY AUTHORITY_HOST")

source = Path(sys.argv[1])
target = Path(sys.argv[2])
operator_key = sys.argv[3]
authority_host = sys.argv[4]

if not re.fullmatch(r"onym:key:[0-9a-f]{64}", operator_key):
    fail("operator key must be onym:key: followed by 64 lowercase hex characters")
if not re.fullmatch(r"[A-Za-z0-9.-]+", authority_host):
    fail("authority host must be a hostname without a scheme or path")

manifest = json.loads(source.read_text(encoding="utf-8"))
manifest["operator"] = operator_key

# The upstream manifest is a reference for authority.onym.app. A staging
# deployment must publish terms on its own host rather than send users to
# production. Rewrite only that known origin, recursively, so new policy URL
# fields inherit the same deployment behavior without rewriting arbitrary URLs.
reference_origin = "https://authority.onym.app"
deployment_origin = f"https://{authority_host}"


def rewrite(value):
    if isinstance(value, dict):
        return {key: rewrite(item) for key, item in value.items()}
    if isinstance(value, list):
        return [rewrite(item) for item in value]
    if isinstance(value, str) and (
        value == reference_origin or value.startswith(reference_origin + "/")
    ):
        return deployment_origin + value[len(reference_origin) :]
    return value


manifest = rewrite(manifest)
target.parent.mkdir(parents=True, exist_ok=True)
rendered = json.dumps(manifest, indent=2, ensure_ascii=False) + "\n"

# Never expose a partly-written manifest to a container during a re-deploy.
with tempfile.NamedTemporaryFile(
    mode="w", encoding="utf-8", dir=target.parent, delete=False
) as handle:
    handle.write(rendered)
    temporary = handle.name
os.chmod(temporary, 0o644)
os.replace(temporary, target)
