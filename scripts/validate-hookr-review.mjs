#!/usr/bin/env node

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const review = JSON.parse(readFileSync(resolve(root, "integrations/hookr/current-review-source.json")));

function verifyHash(base, path, expected) {
  const actual = createHash("sha256").update(readFileSync(resolve(base, path))).digest("hex");
  assert.equal(actual, expected, `${path}: source changed; repeat the Hookr boundary review`);
}

for (const [path, hash] of Object.entries(review.localBoundaryFiles)) {
  verifyHash(root, path, hash);
}

const checkout = process.argv[2];
assert.ok(process.argv.length <= 3, "Usage: node scripts/validate-hookr-review.mjs [hookr-checkout]");

if (checkout) {
  const upstream = resolve(checkout);
  const git = (...args) => execFileSync("git", ["-C", upstream, ...args], { encoding: "utf8" }).trim();
  assert.equal(git("rev-parse", "HEAD"), review.reviewCommit, "Hookr checkout is not at the reviewed commit");
  assert.equal(git("rev-parse", "HEAD^{tree}"), review.reviewTree, "Hookr tree differs from the review");
  git("diff", "--exit-code", "HEAD", "--");

  verifyHash(upstream, review.sourceManifest.path, review.sourceManifest.sha256);
  const manifest = JSON.parse(readFileSync(resolve(upstream, review.sourceManifest.path)));
  assert.equal(manifest.source_commit, review.sourceManifest.canonicalCommit);
  assert.equal(manifest.files.length, review.sourceManifest.verifiedFiles);

  for (const file of manifest.files) {
    verifyHash(upstream, file.path, file.sha256);
  }

  console.log(`Hookr review verified at ${review.reviewCommit} (${manifest.files.length} upstream sources)`);
} else {
  console.log("Hookr local boundary pins verified; pass a Hookr checkout to verify upstream sources");
}
