#!/usr/bin/env node

import { createHash } from "node:crypto";
import { execFile } from "node:child_process";
import { readFile } from "node:fs/promises";
import { dirname, isAbsolute, relative, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const scriptFile = fileURLToPath(import.meta.url);
const root = resolve(dirname(scriptFile), "..");

const defaultManifestPath = resolve(root, "integrations/hookr/manifest.json");
const vendorLockPath = resolve(root, "vendor.lock.json");
const schemaPath = resolve(root, "vendor/hookr-contracts/integrations/hooks/schema.v2.json");
const policyPath = resolve(root, "vendor/hookr-contracts/integrations/hooks/uniswap-policy.v1.json");
const semanticValidatorPath = resolve(root, "vendor/hookr-contracts/scripts/lib/external-hook-standard.mjs");

const expectedHashes = new Map([
  [schemaPath, "048ebc021d1f46d588d21411e4365a177e9788b1231978abbc8f26393b03a85b"],
  [policyPath, "5e0444b1914f069958fca72d32c6e5d521d0c837d7e1d2e8ebdf120e131eafe5"],
  [semanticValidatorPath, "218b7794fabf085d5b21e7c9595e04442a95cb80608bb79554ba9623bc8b988d"],
]);
const expectedHookrRepository = "https://github.com/Hookr-fun/hookr-contracts";
const expectedHookrRevision = "2b0ee64ed85a2d47037efebb8de144cafa23054e";

const schemaKeywords = new Set([
  "$id",
  "$ref",
  "$schema",
  "additionalProperties",
  "allOf",
  "const",
  "contains",
  "definitions",
  "description",
  "else",
  "enum",
  "format",
  "if",
  "items",
  "maxItems",
  "maxLength",
  "minItems",
  "minLength",
  "minimum",
  "pattern",
  "properties",
  "required",
  "then",
  "title",
  "type",
  "uniqueItems",
]);

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function deepEqual(left, right) {
  if (left === right) return true;
  if (Array.isArray(left) && Array.isArray(right)) {
    return left.length === right.length && left.every((value, index) => deepEqual(value, right[index]));
  }
  if (isObject(left) && isObject(right)) {
    const leftKeys = Object.keys(left);
    const rightKeys = Object.keys(right);
    return leftKeys.length === rightKeys.length
      && leftKeys.every((key) => Object.hasOwn(right, key) && deepEqual(left[key], right[key]));
  }
  return false;
}

function childPath(path, key) {
  return /^[A-Za-z_$][A-Za-z0-9_$-]*$/.test(key) ? `${path}.${key}` : `${path}[${JSON.stringify(key)}]`;
}

function assertSupportedSchema(schema, path = "$schema") {
  if (typeof schema === "boolean") return;
  if (!isObject(schema)) throw new Error(`${path} must be a JSON Schema object or boolean`);

  for (const key of Object.keys(schema)) {
    if (!schemaKeywords.has(key)) throw new Error(`${path} uses unsupported JSON Schema keyword ${key}`);
  }

  for (const container of ["definitions", "properties"]) {
    if (schema[container] === undefined) continue;
    if (!isObject(schema[container])) throw new Error(`${path}.${container} must be an object`);
    for (const [key, child] of Object.entries(schema[container])) {
      assertSupportedSchema(child, `${path}.${container}.${key}`);
    }
  }

  for (const key of ["additionalProperties", "contains", "else", "if", "items", "then"]) {
    const child = schema[key];
    if (child !== undefined && (typeof child === "boolean" || isObject(child))) {
      assertSupportedSchema(child, `${path}.${key}`);
    }
  }

  if (schema.allOf !== undefined) {
    if (!Array.isArray(schema.allOf)) throw new Error(`${path}.allOf must be an array`);
    schema.allOf.forEach((child, index) => assertSupportedSchema(child, `${path}.allOf[${index}]`));
  }
}

function resolveReference(rootSchema, reference) {
  if (!reference.startsWith("#/")) throw new Error(`Only local JSON Schema references are supported: ${reference}`);
  return reference
    .slice(2)
    .split("/")
    .map((segment) => segment.replaceAll("~1", "/").replaceAll("~0", "~"))
    .reduce((value, segment) => value?.[segment], rootSchema);
}

function matchesType(value, type) {
  switch (type) {
    case "array":
      return Array.isArray(value);
    case "boolean":
      return typeof value === "boolean";
    case "integer":
      return Number.isInteger(value);
    case "null":
      return value === null;
    case "object":
      return isObject(value);
    case "string":
      return typeof value === "string";
    default:
      throw new Error(`Unsupported JSON Schema type ${type}`);
  }
}

function hasValidFormat(value, format) {
  if (format === "uri") {
    try {
      const hasForbiddenCharacter = [...value].some((character) => {
        const codePoint = character.codePointAt(0);
        return character === "\\" || codePoint <= 0x20 || codePoint === 0x7f;
      });
      return !hasForbiddenCharacter
        && !/%(?![0-9A-Fa-f]{2})/u.test(value)
        && Boolean(new URL(value).protocol);
    } catch {
      return false;
    }
  }
  if (format === "date-time") {
    const match = /^(\d{4})-(\d{2})-(\d{2})[Tt](\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(?:[Zz]|([+-])(\d{2}):(\d{2}))$/u.exec(value);
    if (!match) return false;

    const [, yearText, monthText, dayText, hourText, minuteText, secondText, , offsetHourText, offsetMinuteText] = match;
    const year = Number(yearText);
    const month = Number(monthText);
    const day = Number(dayText);
    const hour = Number(hourText);
    const minute = Number(minuteText);
    const second = Number(secondText);
    const leapYear = year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
    const daysByMonth = [31, leapYear ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];

    if (month < 1 || month > 12 || day < 1 || day > daysByMonth[month - 1]) return false;
    if (hour > 23 || minute > 59 || second > 59) return false;
    if (offsetHourText !== undefined && (Number(offsetHourText) > 23 || Number(offsetMinuteText) > 59)) return false;
    return true;
  }
  throw new Error(`Unsupported JSON Schema format ${format}`);
}

function evaluate(value, schema, rootSchema, path) {
  if (schema === true) return [];
  if (schema === false) return [`${path} is rejected by the schema`];

  const errors = [];
  if (schema.$ref !== undefined) {
    const referenced = resolveReference(rootSchema, schema.$ref);
    if (referenced === undefined) throw new Error(`Unresolved JSON Schema reference ${schema.$ref}`);
    errors.push(...evaluate(value, referenced, rootSchema, path));
  }

  if (schema.type !== undefined) {
    const allowedTypes = Array.isArray(schema.type) ? schema.type : [schema.type];
    if (!allowedTypes.some((type) => matchesType(value, type))) {
      errors.push(`${path} must have type ${allowedTypes.join(" or ")}`);
      return errors;
    }
  }

  if (schema.const !== undefined && !deepEqual(value, schema.const)) {
    errors.push(`${path} must equal ${JSON.stringify(schema.const)}`);
  }
  if (schema.enum !== undefined && !schema.enum.some((candidate) => deepEqual(value, candidate))) {
    errors.push(`${path} must be one of ${schema.enum.map((candidate) => JSON.stringify(candidate)).join(", ")}`);
  }

  if (typeof value === "string") {
    const codePointLength = [...value].length;
    if (schema.minLength !== undefined && codePointLength < schema.minLength) {
      errors.push(`${path} must contain at least ${schema.minLength} characters`);
    }
    if (schema.maxLength !== undefined && codePointLength > schema.maxLength) {
      errors.push(`${path} must contain at most ${schema.maxLength} characters`);
    }
    if (schema.pattern !== undefined && !new RegExp(schema.pattern, "u").test(value)) {
      errors.push(`${path} does not match ${schema.pattern}`);
    }
    if (schema.format !== undefined && !hasValidFormat(value, schema.format)) {
      errors.push(`${path} is not a valid ${schema.format}`);
    }
  }

  if (typeof value === "number" && schema.minimum !== undefined && value < schema.minimum) {
    errors.push(`${path} must be at least ${schema.minimum}`);
  }

  if (Array.isArray(value)) {
    if (schema.minItems !== undefined && value.length < schema.minItems) {
      errors.push(`${path} must contain at least ${schema.minItems} items`);
    }
    if (schema.maxItems !== undefined && value.length > schema.maxItems) {
      errors.push(`${path} must contain at most ${schema.maxItems} items`);
    }
    const hasDuplicate = value.some((item, index) => value.slice(0, index).some((prior) => deepEqual(item, prior)));
    if (schema.uniqueItems && hasDuplicate) {
      errors.push(`${path} must contain unique items`);
    }
    if (schema.items !== undefined) {
      value.forEach((item, index) => errors.push(...evaluate(item, schema.items, rootSchema, `${path}[${index}]`)));
    }
    if (schema.contains !== undefined) {
      const matches = value.some((item, index) => evaluate(item, schema.contains, rootSchema, `${path}[${index}]`).length === 0);
      if (!matches) errors.push(`${path} must contain an item that matches the required schema`);
    }
  }

  if (isObject(value)) {
    const properties = schema.properties ?? {};
    for (const required of schema.required ?? []) {
      if (!Object.hasOwn(value, required)) errors.push(`${childPath(path, required)} is required`);
    }
    for (const [key, child] of Object.entries(properties)) {
      if (Object.hasOwn(value, key)) errors.push(...evaluate(value[key], child, rootSchema, childPath(path, key)));
    }
    const extraKeys = Object.keys(value).filter((key) => !Object.hasOwn(properties, key));
    if (schema.additionalProperties === false) {
      extraKeys.forEach((key) => errors.push(`${childPath(path, key)} is not allowed`));
    } else if (isObject(schema.additionalProperties) || typeof schema.additionalProperties === "boolean") {
      extraKeys.forEach((key) => {
        errors.push(...evaluate(value[key], schema.additionalProperties, rootSchema, childPath(path, key)));
      });
    }
  }

  for (const child of schema.allOf ?? []) errors.push(...evaluate(value, child, rootSchema, path));
  if (schema.if !== undefined) {
    const conditionMatches = evaluate(value, schema.if, rootSchema, path).length === 0;
    if (conditionMatches && schema.then !== undefined) errors.push(...evaluate(value, schema.then, rootSchema, path));
    if (!conditionMatches && schema.else !== undefined) errors.push(...evaluate(value, schema.else, rootSchema, path));
  }

  return errors;
}

export function validateJsonSchema(value, schema) {
  assertSupportedSchema(schema);
  return evaluate(value, schema, schema, "$manifest");
}

async function assertVendoredHashes() {
  for (const [path, expected] of expectedHashes) {
    const content = await readFile(path);
    const observed = createHash("sha256").update(content).digest("hex");
    if (observed !== expected) throw new Error(`${path} SHA-256 mismatch: expected ${expected}, got ${observed}`);
  }

  const vendorLock = JSON.parse(await readFile(vendorLockPath, "utf8"));
  const hookr = vendorLock.dependencies?.["hookr-contracts"];
  if (hookr?.repository !== expectedHookrRepository || hookr?.revision !== expectedHookrRevision) {
    throw new Error("vendor.lock.json does not pin the reviewed Hookr repository and revision");
  }
}

export function normalizeRepository(value) {
  const trimmed = value.trim();
  const scpMatch = /^git@([^:]+):(.+)$/u.exec(trimmed);
  if (scpMatch) {
    return `https://${scpMatch[1].toLowerCase()}/${scpMatch[2].replace(/\.git$/u, "").replace(/\/$/u, "")}`;
  }

  try {
    const url = new URL(trimmed);
    const path = url.pathname.replace(/^\//u, "").replace(/\.git$/u, "").replace(/\/$/u, "");
    if (url.protocol === "ssh:" || url.protocol === "http:" || url.protocol === "https:") {
      return `https://${url.hostname.toLowerCase()}/${path}`;
    }
  } catch {
    // The caller reports the unsupported origin after normalization.
  }

  return trimmed.replace(/\.git$/u, "").replace(/\/$/u, "");
}

async function assertPinnedSource(manifest) {
  const { stdout: origin } = await execFileAsync("git", ["remote", "get-url", "origin"], { cwd: root });
  if (normalizeRepository(origin.trim()) !== normalizeRepository(manifest.source.repository)) {
    throw new Error("Manifest source.repository does not match the Git origin");
  }

  if (!manifest.source.contracts.includes(manifest.source.hookContract)) {
    throw new Error("Manifest source.contracts must include source.hookContract");
  }

  try {
    await execFileAsync("git", ["cat-file", "-e", `${manifest.source.pinnedCommit}^{commit}`], { cwd: root });
  } catch {
    throw new Error(`Manifest source commit is not available locally: ${manifest.source.pinnedCommit}`);
  }

  const { stdout: containingRefs } = await execFileAsync(
    "git",
    ["for-each-ref", `--contains=${manifest.source.pinnedCommit}`, "--format=%(refname)", "refs/remotes/origin"],
    { cwd: root },
  );
  if (!containingRefs.trim()) {
    throw new Error(`Manifest source commit is not contained by a fetched origin ref: ${manifest.source.pinnedCommit}`);
  }

  for (const sourcePath of manifest.source.contracts) {
    const workingPath = resolve(root, sourcePath);
    const relativePath = relative(root, workingPath);
    if (isAbsolute(sourcePath) || relativePath === ".." || relativePath.startsWith("../")) {
      throw new Error(`Manifest contract path must stay inside the repository: ${sourcePath}`);
    }

    let pinnedSource;
    try {
      ({ stdout: pinnedSource } = await execFileAsync(
        "git",
        ["show", `${manifest.source.pinnedCommit}:${sourcePath}`],
        { cwd: root, maxBuffer: 10 * 1024 * 1024 },
      ));
    } catch {
      throw new Error(`Manifest contract path is not available at the pinned commit: ${sourcePath}`);
    }

    let workingSource;
    try {
      workingSource = await readFile(workingPath, "utf8");
    } catch {
      throw new Error(`Manifest contract path is not available in the working tree: ${sourcePath}`);
    }
    if (pinnedSource !== workingSource) {
      throw new Error(`Working ${sourcePath} differs from the manifest's pinned source commit`);
    }
  }
}

export async function validateHookrManifest({ manifest, manifestPath = defaultManifestPath, skipPinnedSource = false } = {}) {
  await assertVendoredHashes();
  const candidate = manifest ?? JSON.parse(await readFile(manifestPath, "utf8"));
  const schema = JSON.parse(await readFile(schemaPath, "utf8"));
  const schemaErrors = validateJsonSchema(candidate, schema);
  if (schemaErrors.length) {
    throw new Error(`Manifest does not match the pinned Hookr schema:\n- ${schemaErrors.join("\n- ")}`);
  }

  const policy = JSON.parse(await readFile(policyPath, "utf8"));
  const { assertExternalHookManifest } = await import(pathToFileURL(semanticValidatorPath));
  assertExternalHookManifest(candidate, policy);
  if (!skipPinnedSource) await assertPinnedSource(candidate);
  return candidate;
}

if (process.argv[1] && resolve(process.argv[1]) === scriptFile) {
  const manifest = await validateHookrManifest({ manifestPath: process.argv[2] ?? defaultManifestPath });
  process.stdout.write(`local-check ${manifest.slug} (${manifest.status})\n`);
  process.stdout.write("checked 1 Hookr manifest draft; upstream AJV was not executed\n");
}
