#!/bin/sh

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

command -v forge >/dev/null 2>&1 || {
    echo "forge is required" >&2
    exit 1
}

run_step() {
    name=$1
    shift
    echo "==> $name"
    if "$@"; then
        echo "<== PASS: $name"
        return 0
    else
        status=$?
        echo "<== FAIL: $name (exit $status)" >&2
        exit "$status"
    fi
}

run_step "forge format" forge fmt --check
run_step "forge build and sizes" forge build --sizes
run_step "forge tests" forge test
hookr_manifest=integrations/hookr/manifest.json
if [ -f "$hookr_manifest" ]; then
    run_step "Hookr manifest source validation" node scripts/validate-hookr-manifest.mjs "$hookr_manifest"
    run_step "Hookr manifest validator tests" env HOOKR_MANIFEST="$hookr_manifest" node --test scripts/validate-hookr-manifest.test.mjs
elif [ -f docs/hookr.md ] || [ -d integrations/hookr ]; then
    echo "Hookr integration files exist but integrations/hookr/manifest.json is missing" >&2
    exit 1
else
    echo "Hookr manifest: skipped (add a project-specific integrations/hookr/manifest.json to enable)"
fi
if command -v slither >/dev/null 2>&1; then
    run_step "slither fail-high" slither . --filter-paths 'vendor/' --fail-high
elif [ "${REQUIRE_SLITHER:-0}" = "1" ]; then
    echo "slither is required when REQUIRE_SLITHER=1" >&2
    exit 1
else
    echo "slither: skipped (set REQUIRE_SLITHER=1 to make it mandatory)" >&2
fi

echo "CHECK_OK"
