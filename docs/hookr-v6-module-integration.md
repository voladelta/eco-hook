# Hookr V6 typed Eco module

## Implemented shape

Eco's V6 candidate uses Hookr's supported read-only policy lane with stateful, direction-bound claim
strategies:

```text
Hookr modular root
  -> EcoBasketModuleV1 (STATICCALL policy)
  -> Hookr mints native-quote ERC-6909 claims
  -> EcoBasketClaimStrategyV1 (buy or sell state)
  -> permissionless claim settlement
  -> EcoBasketModuleVault
  -> basket / buyback / liquidity accounting
```

The module itself is read-only because the pinned Hookr V6 catalog reserves `STATEFUL_V1` for Native
Mechanics. Eco's state lives in the claim strategies and vault. This is the same separation used by
Hookr's directional-tax policy and strategy boundary.

## Contracts

- `EcoBasketModuleRegistry` is the immutable preparation and strategy-attestation boundary. Its
  approved adapter prepares one native-quote dynamic-fee `PoolKey`.
- `EcoBasketModuleV1` is the typed Hookr policy. It validates the exact pool, kernel, PoolManager,
  strategy runtimes, direction, preset, and Eco config commitment before stack admission.
- `EcoBasketClaimStrategyV1` receives quote-currency ERC-6909 claims from one immutable Hookr kernel
  for one pool direction. Anyone may settle backed claims, but funds can go only to its immutable
  vault.
- `EcoBasketModuleVault` accepts accounting only from its activated buy or sell strategy and reuses
  Eco's isolated allocation and bounded release lifecycle.
The module vault keeps its accounting local rather than refactoring the existing standalone
`EcoVault`, which remains byte-for-byte aligned with its pinned source manifest.

## Fee behavior

All module fees are native quote, including buys. This removes the standalone hook's strategy-token
buy-fee limitation.

| Swap | Hookr phase | Fee |
| --- | --- | ---: |
| Exact-input buy | `beforeSwap` specified quote | preset buy fee |
| Exact-output buy | `afterSwap` unspecified quote gross-up | preset buy fee |
| Exact-input sell | `afterSwap` unspecified quote | preset sell fee |
| Exact-output sell | `beforeSwap` specified quote | preset sell fee |

The presets remain Growth 1.00%/0.00%, Balanced 0.75%/0.25%, and Neutral 0.50%/0.50%. The module
shares Hookr's `DIRECTIONAL_QUOTE_TAX` exclusive group, so a pool cannot select both Eco and Hookr's
separate directional-tax block.

The Hookr kernel, not Eco, calculates and mints each fee claim. Eco does not trust the router, payer,
recipient, `zeroForOne`, or arbitrary hook data to infer direction. The kernel supplies `isBuy` and
`exactInput` from the frozen pool stack.

## Preparation and admission

The integration sequence is:

1. Deploy `EcoBasketModuleRegistry(approvedAdapter, approvedExecutor)`. It deploys the singleton
   `EcoBasketModuleV1` and one shared `NarrativeOrderHub`.
2. Hookr reviews and registers that exact module runtime as `READ_ONLY`, then admits it in a new
   sealed root profile.
3. The approved adapter constructs the final native-quote `PoolKey` using the admitted Hookr kernel
   and dynamic-fee flag.
4. The adapter calls `preparePool`. The registry deploys one vault, a buy strategy, and—unless Growth
   is selected—a sell strategy. It returns canonical module config bytes.
5. The Hookr market transaction uses those exact bytes in its `ModuleSelection` and freezes the
   resulting stack before pool initialization.

The proposed catalog registration is:

| Field | Value |
| --- | --- |
| `moduleKey` | `keccak256("ECO_BASKET_QUOTE_FEE")` |
| `version` | `1` |
| `implementation` | reviewed `EcoBasketModuleV1` address |
| `configSchemaHash` | module's `CONFIG_SCHEMA_HASH()` |
| `requiredHookFlags` | `0x28cc` for the pinned full V4 root |
| `phaseMask` | before-swap and after-swap |
| `exclusiveGroup` | `keccak256("DIRECTIONAL_QUOTE_TAX")` |
| `executionMode` | `READ_ONLY` |
| specified/unspecified quote caps | 100 bps |
| subject-take cap | zero |

Preparation is safe to retry at the Hookr market-opening layer: a prepared pool can be submitted
again with the same stored module config, while the Eco registry rejects a second preparation. A
failed or abandoned preparation holds no user funds.

## Claim settlement

For each fee:

1. Hookr mints ERC-6909 native-quote claims to the direction's strategy.
2. Hookr calls `creditClaims`; the strategy accepts only its immutable kernel and verifies that the
   claims already back its updated accounting.
3. Any caller may call `settleClaims` with a bounded amount.
4. The strategy updates accounting before unlocking the PoolManager.
5. Its PoolManager-only callback burns the claims and takes native quote directly to the immutable
   vault.
6. The vault verifies the direction-bound strategy and records the existing Eco allocation split.

The complete operation reverts atomically if claim backing, PoolManager settlement, native transfer,
or vault accounting fails. The caller cannot choose a recipient.

## Remaining Hookr work

This repository now provides the Eco-side candidate, not a production admission:

- Hookr must register the module and include it in a newly reviewed sealed profile.
- The V6 SDK needs a typed Eco config/preparation builder and transaction ordering.
- The approved adapter must be bound to Hookr's market-opening authority.
- Tests must run through the real Hookr root, StackRegistry, coordinator, router, quoter, and
  PoolManager rather than the local claim-settlement mock.
- Exact-output behavior remains conditional on Hookr's router, launch-guard, and aggregate fee rules.
- Deployment hashes, target-chain fork evidence, gas limits, audit, and explicit Hookr approval are
  still required.
