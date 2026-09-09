#!/bin/sh

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
checkout=${HOOKR_REVIEW_CHECKOUT:-"$root/../hookr-modular-hooks"}
checkout=$(CDPATH= cd -- "$checkout" && pwd)

node "$root/scripts/validate-hookr-review.mjs" "$checkout"

submodules=$(git -C "$checkout" submodule status --recursive)
if printf '%s\n' "$submodules" | grep -Eq '^[-+U]'; then
    echo "Hookr submodules must match their pins. Run: git -C '$checkout' submodule update --init --recursive" >&2
    exit 1
fi

# Keep Hookr's compiler and v4-core separate from Eco's standalone build.
export FOUNDRY_PROFILE=default
FOUNDRY_REMAPPINGS=$(printf '%s\n' \
    "eco/=$root/" \
    "hookr/=$checkout/src/" \
    "@uniswap/v4-core/=$checkout/lib/v4-core/" \
    "forge-std/=$checkout/lib/forge-std/src/" \
    "@openzeppelin/=$checkout/lib/v4-core/lib/openzeppelin-contracts/" \
    "solmate/=$checkout/lib/v4-core/lib/solmate/")
export FOUNDRY_REMAPPINGS

forge fmt --check --root "$root/integrations/hookr-local"
forge test --root "$root/integrations/hookr-local" "$@"
