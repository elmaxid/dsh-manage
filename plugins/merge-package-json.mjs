#!/usr/bin/env node
// Merge the plugin stack declared in manifest.json into a profile's
// package.json. Called by `dsh-manage plugins-install` (never run directly
// by a user).
//
// Usage: node merge-package-json.mjs <existingPackageJsonPath> <manifestJsonPath> <profileName>
// Prints the merged package.json (JSON, 2-space indent) to stdout.
//
// Merge rules:
//   - dependencies: existing version specifiers win on conflict (never
//     downgrade/override something a human already bumped by hand); manifest
//     only fills in keys that are missing.
//   - dsh.profile.bundles: append-only. Bundle order is the Cordis patch-layer
//     application order, so re-ordering an existing bundle list is unsafe —
//     existing bundles keep their position, and manifest bundles not already
//     present are appended in the manifest's own order.
// If existingPackageJsonPath does not exist yet (new profile), starts from a
// minimal skeleton instead.

import { readFileSync, existsSync } from 'node:fs';

const [, , existingPath, manifestPath, profileName] = process.argv;

if (!manifestPath || !profileName) {
  console.error('uso: merge-package-json.mjs <existing-package.json> <manifest.json> <profileName>');
  process.exit(1);
}

const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));

let pkg;
if (existingPath && existsSync(existingPath)) {
  pkg = JSON.parse(readFileSync(existingPath, 'utf8'));
} else {
  pkg = {
    name: `dsh-profile-${profileName}`,
    private: true,
    dependencies: {},
    dsh: { profile: { bundles: [] } },
  };
}

pkg.dependencies = pkg.dependencies || {};
for (const [name, range] of Object.entries(manifest.dependencies)) {
  if (!(name in pkg.dependencies)) {
    pkg.dependencies[name] = range;
  }
}

pkg.dsh = pkg.dsh || {};
pkg.dsh.profile = pkg.dsh.profile || {};
const existingBundles = pkg.dsh.profile.bundles || [];
const existingSet = new Set(existingBundles);
const appended = manifest.bundles.filter((b) => !existingSet.has(b));
pkg.dsh.profile.bundles = [...existingBundles, ...appended];

process.stdout.write(JSON.stringify(pkg, null, 2) + '\n');
