# Eco Basket V1

Eco Basket V1 is a source-only Uniswap v4 hook for strategy tokens launched by Hookr. One non-upgradeable hook supports many pools. Each approved pool has immutable fee and basket rules and one isolated vault.

This repository does not create tokens, pools, launch liquidity, or a router. Hookr owns those parts of the launch. The strategy token must remain a plain fixed-supply Hookr token.

## Current behavior

The approved adapter prepares a pool once. The pool must use native quote as `currency0`, the strategy token as `currency1`, and this hook. `beforeInitialize` consumes the prepared record and makes it active. There is no owner, upgrade path, or mutable allowlist.

Deployment also fixes one nonzero approved executor. This product-owned address is an explicit trusted custody boundary. It cannot change a pool configuration or choose another fund recipient. It can schedule basket orders, release only due order funds to itself, and release recorded buyback or liquidity funds to itself. This repository does not define what the executor does with released funds and does not implement external swaps.

The reviewed fee presets are:

| Preset | Buy | Sell |
| --- | ---: | ---: |
| Growth | 1.00% | 0.00% |
| Balanced | 0.75% | 0.25% |
| Neutral | 0.50% | 0.50% |

Each preset has `buyFeeBps + sellFeeBps <= 100`.

Both exact-input directions are supported. The hook takes the fee from the unspecified output currency and returns the same positive `afterSwap` delta. A buy fee is collected in strategy-token output. It is not a native quote basket budget. A sell fee is collected in native quote output.

Buy fee accounting is 80% basket, 10% strategy-token buyback, and 10% liquidity. Sell fee accounting is 50% buyback and 50% liquidity. Integer division remainders stay in the final allocation, so all collected value is recorded.

Both exact-output directions are rejected atomically before fee accounting. Hookr PR 3 does not publish the router, quoter, or prefund ABI needed to gross up exact output safely. This release does not guess those interfaces.

The hook callback does not execute basket swaps, buybacks, liquidity operations, or order creation. The fixed executor can convert one vault's basket budget into at most eight deterministic order records. The contracts derive each start time from the scheduling block. A caller cannot supply time. Each order has at most 32 total steps, and one executor call advances at most eight steps. The order hub updates state before the vault transfers due native or ERC20 funds to the fixed executor. After expiry, any caller can restore unreleased funds to the vault's basket allocation.

Buyback and liquidity funds use separate bounded release accounting. Basket funds cannot use those release paths and can leave a vault only when a scheduled step is due. All releases go to the fixed executor. There is no general withdrawal function.

## Contracts

- `EcoBasketHook` owns PoolManager callback behavior and fee collection.
- `EcoPoolRegistry` owns one-time preparation, activation, reviewed presets, and vault identity.
- `EcoVault` owns one pool's assets and allocation accounting.
- `NarrativeOrderHub` owns the bounded scheduled-order lifecycle.

## Checks

```sh
forge fmt --check
forge test --match-path 'test/unit/EcoPoolRegistry.t.sol'
forge test --match-path 'test/integration/EcoBasketHook.t.sol'
node --test scripts/validate-hookr-manifest.test.mjs
./scripts/check.sh
```

The Hookr manifest pins the immutable source commit and route evidence. Run the full schema, semantic, and source check with:

```sh
node scripts/validate-hookr-manifest.mjs integrations/hookr/manifest.json
```

## Hookr scope and status

The integration vendors only the external-hook V2 schema, semantic validator, and Uniswap policy from Hookr contracts PR 3 head `2b0ee64ed85a2d47037efebb8de144cafa23054e`. It does not include or infer a Hookr launch, router, token, native-block, or executor ABI. The approved executor is an Eco product authority, not a Hookr interface.

This code is unaudited. It is not deployed, approved for production, or submitted for listing.
