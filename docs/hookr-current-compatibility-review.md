# Current Hookr compatibility assessment

## Result and source boundary

Reviewed on 2026-09-09 against `Hookr-fun/hookr-modular-hooks` commit
`486a8e62767977c06bb82db43e73e816e0545038`, matching `origin/main` at review time.
The local checkout was `../hookr-modular-hooks`. Its source manifest binds 41 Solidity files to
canonical Hookr commit `8db7fc940938f811f508ba9cb0c8f2d3f24c9a25`.

Eco remains an unadmitted integration candidate. The standalone root has no supported selection
path. The typed policy and claim-strategy design retains the current ABI, but a source match does
not establish composition or settlement through the deployed release.

[`current-review-source.json`](../integrations/hookr/current-review-source.json) records the pin,
manifest hash, local boundary hashes, and conclusions. The [older V6 review](hookr-v6-compatibility-review.md)
and its evidence file remain historical. The separate `hookr-contracts` external-hook schema pin
does not change: it describes the standalone artifact, not this modular release.

## Reviewed changes

Upstream references below are relative to the pinned
[source tree](https://github.com/Hookr-fun/hookr-modular-hooks/tree/486a8e62767977c06bb82db43e73e816e0545038).

| Boundary | Current evidence | Eco consequence |
| --- | --- | --- |
| Release | `README.md`, `SOURCE_MANIFEST.json`, `deployments/robinhood-4663.v2.json` | Upstream reports a deployed, unaudited chain-4663 release. It is no longer just the historical V6 handoff packet. |
| Root | `src/HookrModularHookV6.sol`, `src/HookrStackRegistryV2.sol` | V6 root identity, `0x28cc` flags, sealed shared profiles; no per-market kernel-instance lane. Eco's standalone `0x2044` root is not selectable. |
| Coordinator | `src/HookrMarketCoordinatorV5.sol`, `_openMarket` | Derives the pool key from the active kernel, requires Native Mechanics, freezes the stack, then initializes. No Eco preparation owner is supplied. |
| Native admission | `src/libraries/HookrNativeMechanicsCoordinatorLibV2.sol` | Validates canonical Native Mechanics V2, schema, stateful mode, creator share, and immutable treasury. An Eco-only selection fails. |
| Policy and claims | `src/interfaces/IHookrModuleV1.sol`, `src/interfaces/IHookrClaimSinkV1.sol`, `src/libraries/HookrModuleTypesV1.sol` | Unchanged since the earlier pin. Eco's interface signatures and retained struct layouts match; no fee-contract rewrite is justified by this update. |
| Accounting | `src/HookrSwapAccountingKernelV3.sol` | Byte-identical to the earlier pin; read-only policy results still mint quote ERC-6909 claims before `creditClaims`. |
| Catalog and profile | `src/HookrModuleCatalogV1.sol`, `src/HookrStackRegistryV1.sol`, deployment identifiers | The current release admits Native Mechanics; no Eco module appears in the package. Registration cannot expand an already sealed profile. |
| Client | Former `packages/v6-sdk` and V6 handoff paths are absent | Do not prescribe the removed SDK as the current integration surface. Build preparation and market encoding against an agreed current client contract. |

The retained `src/hookr-v6/` directory is Eco's existing ABI subset. It does not vendor the old SDK
or bind the candidate to the historical root runtime. Its interface hashes record the manually
reviewed match; the source checker detects drift, rather than claiming to perform an ABI audit.

## Current integration requirements

### Admission and preparation

Hookr must approve and deploy a new profile containing both its required Native Mechanics module
and Eco's read-only policy. The one canonical stateful module remains Native Mechanics; Eco's
mutable state remains in its direction-bound claim strategies and vault. Catalog registration
alone cannot admit Eco into the existing sealed profile or modify existing pools.

The launcher must derive the final subject address and dynamic-fee pool key, prepare Eco's registry
through its immutable approved adapter, then submit the exact returned config in `ModuleSelection`.
The adapter must be connected to the actual market-opening caller. Preparation and launch require
defined ordering and retry behavior; they are not wired together by this repository yet.

### Creator and revenue rules

Read upstream `docs/guides/integrating-as-a-launcher.md`,
`docs/concepts/protocol-share-and-treasury.md`, and `docs/reference/config-schema-and-limits.md`.
The calling launcher is the creator, including for share-tier resolution and intent replay scope.
Its user is not automatically the creator. The founding LP fee recipient is a separate field.

The former partner directional-tax requirement is not the current release model. V5 resolves a
creator tier; Native Mechanics V2 takes a bounded share of its opt-in add-ons, with no share of the
base LP fee. The published default is 20%, the ceiling is 50%, and a creator tier can be zero. The
launcher must read its resolved share in the launch transaction and encode matching native config.

These rules do not establish an automatic protocol share of Eco's fees. Eco still allocates its own
claims according to its presets. Any additional Eco revenue agreement requires an explicit design
and review. Eco's retained `DIRECTIONAL_QUOTE_TAX` exclusive group is not evidence that the removed
directional-tax module remains part of the deployed release.

### Swap and settlement matrix

Read upstream `docs/guides/swapping-and-quoting.md`, `docs/concepts/fee-model.md`,
`docs/concepts/guard-window.md`, and `docs/security/known-limitations.md`.

- Eco remains native-quote-only even though Hookr now supports ERC-20 quotes.
- Eco's fee table describes its policy contribution, not the pool's total fee. Test combined caps,
  rounding, donations, claim backing, and final wallet/vault balances alongside Native Mechanics.
- Native Mechanics blocks exact-output buys during the launch guard. Eco's support for the policy
  quadrant cannot override that rejection. Outside the guard, exact-output swaps use the native
  surge ceiling rather than the exact-input size calculation.
- The native pot depends on the registered router/quoter. Universal Router swaps with empty hook
  data do not participate in that pot. Test each router's actual final balances separately.
- Eco charges specified-quote fees on exact-input buys. Review the kernel's partial-fill rejection
  with those fees enabled, including otherwise base-fee-only native configurations.
- Pin the tested Universal Router address and runtime. Upstream's deployment record lists two
  different candidates, rather than one authoritative tested router for all callers.

No Eco deployment, profile admission, real-root settlement test, target-chain fork run, or on-chain
verification was performed as part of this source refresh. Upstream canaries remain evidence only
for the upstream configuration. Production approval and an independent audit remain outstanding.

## Reproduce the source check

```sh
node scripts/validate-hookr-review.mjs ../hookr-modular-hooks
HOOKR_REVIEW_CHECKOUT=../hookr-modular-hooks ./scripts/check.sh
```

The first command verifies the exact checkout commit/tree, absence of tracked changes, pinned
manifest, all 41 manifest sources, and Eco's local boundary files. A different upstream commit
requires a new review; the checker never fetches or changes either checkout.

The upstream `node check-source-manifest.mjs` and `node check-review-boundary.mjs` checks also passed
at this pin. These establish exported source consistency. They do not reproduce deployed bytecode
or verify the canonical source repository independently.

Eco's full `scripts/check.sh` passed with that checkout: formatting, build and sizes, Forge tests,
the current source check, standalone manifest validation and validator tests, and Slither's
`--fail-high` gate. Slither still reports findings below that gate; this is not a clean audit.
The current source checker also rejected an incorrect checkout revision. No Solidity behavior
changed in this refresh, and those existing tests do not establish settlement through Hookr's root.
