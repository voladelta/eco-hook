import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";

import { normalizeRepository, validateHookrManifest, validateJsonSchema } from "./validate-hookr-manifest.mjs";

const manifestPath = process.env.HOOKR_MANIFEST ?? new URL("../integrations/hookr/manifest.json", import.meta.url);
const baseManifest = JSON.parse(await readFile(manifestPath, "utf8"));

test("accepts the Eco Basket draft schema and PR-pinned semantic rules", async () => {
  await assert.doesNotReject(
    validateHookrManifest({ manifest: structuredClone(baseManifest), skipPinnedSource: true }),
  );
});

test("rejects a return-delta permission without its callback", async () => {
  const manifest = structuredClone(baseManifest);
  manifest.uniswapClassification.flags.beforeSwap = false;
  manifest.uniswapClassification.flags.beforeSwapReturnsDelta = true;

  await assert.rejects(validateHookrManifest({ manifest, skipPinnedSource: true }), /beforeSwap/u);
});

test("rejects an enabled callback without callback semantics", async () => {
  const manifest = structuredClone(baseManifest);
  manifest.uniswapClassification.callbackSemantics = manifest.uniswapClassification.callbackSemantics.filter(
    ({ name }) => name !== "afterSwap",
  );

  await assert.rejects(validateHookrManifest({ manifest, skipPinnedSource: true }), /afterSwap|contain an item/u);
});

test("rejects a source commit that cannot supply the hook", async () => {
  const manifest = structuredClone(baseManifest);
  manifest.source.pinnedCommit = "0000000000000000000000000000000000000000";

  await assert.rejects(validateHookrManifest({ manifest }), /source commit/u);
});

test("rejects a contract path that the pinned commit cannot supply", async () => {
  const manifest = structuredClone(baseManifest);
  manifest.source.contracts.push("src/DoesNotExist.sol");

  await assert.rejects(validateHookrManifest({ manifest }), /contract path/u);
});

test("rejects a normalized but impossible calendar date", async () => {
  const manifest = structuredClone(baseManifest);
  manifest.security.frameworkAssessment.assessedAt = "2025-02-30T00:00:00Z";
  manifest.security.frameworkAssessment.scoreStatus = "scored";
  manifest.security.frameworkAssessment.score = 1;

  await assert.rejects(validateHookrManifest({ manifest, skipPinnedSource: true }), /valid date-time/u);
});

test("accepts lowercase RFC 3339 date-time separators", async () => {
  const manifest = structuredClone(baseManifest);
  manifest.security.frameworkAssessment.assessedAt = "2025-02-28t00:00:00z";
  manifest.security.frameworkAssessment.scoreStatus = "scored";
  manifest.security.frameworkAssessment.score = 1;

  await assert.doesNotReject(validateHookrManifest({ manifest, skipPinnedSource: true }));
});

test("rejects unsupported leap-second timestamps", async () => {
  const manifest = structuredClone(baseManifest);
  manifest.security.frameworkAssessment.assessedAt = "2025-02-28T12:00:60Z";
  manifest.security.frameworkAssessment.scoreStatus = "scored";
  manifest.security.frameworkAssessment.score = 1;

  await assert.rejects(validateHookrManifest({ manifest, skipPinnedSource: true }), /valid date-time/u);
});

test("rejects malformed URI percent escapes", async () => {
  const manifest = structuredClone(baseManifest);
  manifest.author.website = "https://example.com/%zz";

  await assert.rejects(validateHookrManifest({ manifest, skipPinnedSource: true }), /valid uri/u);
});

test("rejects backslashes that a WHATWG URL would normalize", async () => {
  const manifest = structuredClone(baseManifest);
  manifest.security.auditUrls = ["https://example.com/foo\\bar"];

  await assert.rejects(validateHookrManifest({ manifest, skipPinnedSource: true }), /valid uri/u);
});

test("counts JSON Schema string length in Unicode code points", () => {
  assert.deepEqual(validateJsonSchema("😀".repeat(50), { type: "string", maxLength: 80 }), []);
});

test("treats objects with reordered properties as duplicate JSON values", () => {
  const errors = validateJsonSchema(
    [{ left: 1, right: 2 }, { right: 2, left: 1 }],
    { type: "array", uniqueItems: true },
  );
  assert.match(errors.join("\n"), /unique items/u);
});

test("rejects fields outside the pinned schema", async () => {
  const manifest = structuredClone(baseManifest);
  manifest.unpublishedCompatibilityClaim = true;

  await assert.rejects(validateHookrManifest({ manifest, skipPinnedSource: true }), /is not allowed/u);
});

test("normalizes common GitHub clone transports", () => {
  const expected = "https://github.com/voladelta/eco-hook";
  assert.equal(normalizeRepository("git@github.com:voladelta/eco-hook.git"), expected);
  assert.equal(normalizeRepository("ssh://git@github.com/voladelta/eco-hook.git"), expected);
  assert.equal(normalizeRepository("https://github.com/voladelta/eco-hook.git"), expected);
});
