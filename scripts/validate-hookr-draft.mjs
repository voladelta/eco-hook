#!/usr/bin/env node

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFile } from "node:fs/promises";

import { validateHookrManifest } from "./validate-hookr-manifest.mjs";

const manifest = JSON.parse(await readFile(new URL("../integrations/hookr/manifest.json", import.meta.url), "utf8"));
const head = execFileSync("git", ["rev-parse", "HEAD"], { encoding: "utf8" }).trim();
assert.equal(manifest.source.pinnedCommit, head, "draft pinnedCommit must equal repository HEAD");
await validateHookrManifest({ manifest, skipPinnedSource: true });
process.stdout.write(`draft-check ${manifest.slug} (${manifest.status}); immutable source check pending commit\n`);
