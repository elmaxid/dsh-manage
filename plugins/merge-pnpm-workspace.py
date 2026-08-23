#!/usr/bin/env python3
"""Merge the manifest's pnpm-workspace settings (allowBuilds, patchedDependencies,
etc.) into a profile's pnpm-workspace.yaml. Called by `dsh-manage plugins-install`
(never run directly by a user).

Usage: merge-pnpm-workspace.py <existing-pnpm-workspace.yaml-or-missing> <manifest.json>

Prints the merged YAML to stdout.

Merge rules:
  - allowBuilds / patchedDependencies: existing entries win on conflict (a
    human may have hand-tuned a build flag or added an unrelated patch);
    manifest only fills in keys that are missing.
  - patchedDependencies paths from the manifest are always relative to the
    dsh-manage repo's plugins/patches/ dir when first added by this merge —
    the caller (dsh-manage.sh) is responsible for having already copied the
    .patch files into the profile's own patches/ dir before this runs.
  - scalar settings (nodeLinker, autoInstallPeers, strictDepBuilds): existing
    value wins if already set; manifest value used only to fill a missing key.
  - 'packages: [.]' is always ensured (pnpm requires it for a workspace root).
"""
import sys
import json
import yaml

existing_path, manifest_path = sys.argv[1], sys.argv[2]

try:
    with open(existing_path) as f:
        existing = yaml.safe_load(f) or {}
except FileNotFoundError:
    existing = {}

with open(manifest_path) as f:
    manifest = json.load(f)

ws = manifest.get("pnpmWorkspace", {})

if "packages" not in existing:
    existing["packages"] = ["."]

for scalar_key in ("nodeLinker", "autoInstallPeers", "strictDepBuilds"):
    if scalar_key in ws and scalar_key not in existing:
        existing[scalar_key] = ws[scalar_key]

existing.setdefault("allowBuilds", {})
for pkg, allowed in ws.get("allowBuilds", {}).items():
    if pkg not in existing["allowBuilds"]:
        existing["allowBuilds"][pkg] = allowed

existing.setdefault("patchedDependencies", {})
for spec, path in manifest.get("patchedDependencies", {}).items():
    if spec not in existing["patchedDependencies"]:
        existing["patchedDependencies"][spec] = path

print(yaml.safe_dump(existing, default_flow_style=False, sort_keys=False, allow_unicode=True), end="")
