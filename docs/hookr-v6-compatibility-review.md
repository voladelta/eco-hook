# Hookr V6 compatibility review

## Result

The deployed Eco Basket V1 standalone hook is **not compatible** with the Hookr V6 market-opening path reviewed at
`Hookr-fun/hookr-modular-hooks@aa5c93b32c22b2f3cf5742fd2c314822406d428f`.

This is an integration-boundary mismatch, not evidence of a defect in either implementation:

- Hookr V6 creates a pool whose only hook is an admitted Hookr modular root.
- Eco Basket V1 is itself a complete Uniswap v4 hook and requires its approved adapter to prepare
  the exact Eco `PoolKey` before that hook receives `beforeInitialize`.
- The reviewed V6 SDK has no external-root selection, Eco preparation call, or Eco module config.

The Eco-side [typed module candidate](hookr-v6-module-integration.md) now implements the selected
policy-module, claim-strategy, and vault boundaries. It is not yet admitted by Hookr: the pinned V6
profile and SDK do not include Eco. A separate external-root lane remains out of scope.

## Review boundary

The review started with the three requested artifacts:

1. `SOURCE_MANIFEST.json`
2. `packages/v6-sdk`
3. `docs/uniswap-review/v6/evidence/final-fixes-ui-handoff.json`

The private review repository was checked out at the exact commit above. Its source-manifest checker
verified all 98 entries. The manifest binds the exported SDK and relevant Solidity sources to
`Hookr-fun/hookr@eab768dc6ba7c1264a86a91ad9817972ccbbcc21`.

The exact artifact hashes are recorded in
[`integrations/hookr/v6-review-source.json`](../integrations/hookr/v6-review-source.json). No private
Hookr source, SDK implementation, ABI payload, address packet, or operator data is copied into this
repository.

## Compatibility matrix

| Boundary | Status | Evidence and consequence |
| --- | --- | --- |
| One hook per pool | Conceptually aligned | Both systems treat the `PoolKey.hooks` address as immutable. They disagree on which root owns the callback boundary. |
| Multi-pool immutable configuration | Conceptually aligned | Eco has immutable per-`PoolId` config under one root. Hookr has frozen per-`PoolId` module stacks under one admitted root. |
| Native quote orientation | Aligned for native markets | Eco requires native `currency0`; Hookr sorts native address zero before the subject token. This does not provide a launch path by itself. |
| Root selection | Blocked | The SDK accepts only `shared` or `dedicated`. A dedicated request must resolve to a genuine `HookrModularHookV4` 4.0.0 deployment with the shared template runtime and exact `0x28cc` hook flags. Eco is a different runtime with `0x2044` flags. |
| Pool preparation | Blocked | Eco requires `preparePool` by its immutable approved adapter before initialization. The reviewed coordinator derives the hook from an active Hookr kernel, prepares/freezes the Hookr stack, and initializes that pool. It exposes no Eco preparation step. |
| Typed module composition | Blocked for the standalone hook | The standalone Eco root does not implement the Hookr module ABI. The new candidate does, but the reviewed catalog/profile has not admitted it and the SDK does not export an Eco config encoder. |
| Dynamic LP fee model | Blocked as a root replacement | Hookr market keys use the dynamic-fee flag and native mechanics module. Eco declares no dynamic-fee behavior and cannot replace that root while preserving the reviewed Hookr market contract. |
| Exact-input routing | Unproven for Eco | Hookr's canary evidence covers its admitted shared root. Eco's tests cover `PoolSwapTest`, not the reviewed Universal Router against Eco. Evidence does not transfer between hook addresses. |
| Exact-output routing | Unsupported by Eco | Eco intentionally rejects both exact-output directions. The V6 handoff includes router/quoter ABI evidence, but the private SDK does not export transaction helpers and no reviewed path integrates that routing with the Eco root. |
| Production activation | Not authorized | The handoff is marked `INTEGRATION_REFERENCE_NOT_PRODUCTION_ACTIVATION`, has production activation disabled, and explicitly does not claim complete end-to-end UI or SDK coverage. |

## Blocking findings

### 1. Hookr cannot select the Eco root

`planHookDeployment` classifies only shared and dedicated Hookr roots. Dedicated admission is not a
generic custom-hook lane: it requires the exact reviewed Hookr root identity, runtime equivalence,
registry profile, and `0x28cc` permission flags. Eco's permission set is `beforeInitialize`,
`afterSwap`, and `afterSwapReturnDelta`, which encodes to `0x2044`.

The coordinator then builds the `PoolKey` with the active kernel implementation as `hooks`. Passing
the Eco address would bypass the admitted kernel/profile model and is not accepted by the reviewed
SDK or coordinator.

### 2. Eco's required pre-initialization call has no owner in V6

Eco's safety rule is:

1. the immutable approved adapter calls `EcoPoolRegistry.preparePool`;
2. `PoolManager.initialize` calls Eco's `beforeInitialize`;
3. Eco consumes and activates the prepared record.

The V6 coordinator instead owns Hookr stack admission and pool initialization. Neither coordinator
call encoded by the SDK carries the Eco basket, preset, schedule, or an Eco adapter authorization.
There is therefore no atomic or ordered path that can satisfy Eco's existing activation invariant.

### 3. Eco cannot be relabeled as a Hookr module

The module route needs a real port, not an ABI shim. Eco currently owns:

- stateful fee accounting in `afterSwap`;
- an isolated vault per pool;
- basket, buyback, and liquidity allocations;
- scheduled release state; and
- an immutable executor custody boundary.

A Hookr-native implementation must map those guarantees onto an admitted module execution mode,
config schema, root settlement semantics, and beneficiary model. The current stateful catalog lane
is restricted, and the SDK's documented supported surface contains no builder-supplied module or
typed generic config encoder.

### 4. Router evidence does not close the root mismatch

The V6 packet is useful evidence: it identifies reviewed router, quoter, Permit2, coordinator, and
root ABIs and records successful canary coverage. That evidence is scoped to the admitted Hookr
root. It does not establish that the same router settles Eco's return delta, supplies Eco-compatible
hook data, or handles Eco's deliberate exact-output reverts.

## Selected integration: typed Eco policy with stateful claim strategies

This preserves Hookr as the only pool hook and keeps the existing coordinator, voucher, router, and
root identity model. Hookr and Eco would need to specify:

1. a versioned Eco module config containing the preset, basket tokens, order interval, and steps;
2. the stateful module execution and settlement ABI for subject-output buy fees and quote-output
   sell fees;
3. per-pool vault creation and the point at which its address becomes voucher-bound;
4. module admission authority, codehash/profile evidence, caps, gas limits, and conflicts;
5. executor and beneficiary authority;
6. exact-input and exact-output behavior for all four swap quadrants; and
7. SDK encoders, reads, events, simulation, and final-wallet test vectors.

The Eco candidate implements this shape. It still requires Hookr catalog/profile/SDK work and should
not reuse the current standalone manifest as proof of module admission.

The existing standalone hook remains useful as behavior and accounting evidence while the module is
designed. It is not the deployable integration artifact. The module design should reuse Eco's
per-pool vault and bounded order lifecycle where those guarantees fit Hookr's settlement model, and
replace the standalone `beforeInitialize` activation path with Hookr stack/config admission.

An external Eco root, coordinator bypass, second pool hook, or private adapter calldata path is not
an accepted fallback.

## Acceptance evidence for a future integration

A compatibility claim requires all of the following against one pinned Hookr release and one pinned
Eco source:

- the SDK builds the exact Eco-bearing market transaction without private ad hoc calldata;
- preparation, stack/config admission, pool initialization, and Eco activation complete atomically
  or have defined retry and cleanup behavior;
- the resulting `PoolKey`, `PoolId`, hook/root identity, config hash, vault, and voucher commitments
  agree on-chain and in the SDK;
- official router and quoter tests cover exact input and exact output in both directions, empty and
  non-empty hook data, third-party recipients, refunds, and final wallet/vault balances;
- unsupported modes fail before any fee or vault state changes;
- deployment/runtime hashes and immutable constructor arguments are reproduced; and
- Hookr and Eco explicitly approve that exact evidence packet for production.

Until then, Eco remains a source-reviewed standalone hook candidate, not a Hookr V6-compatible
market option.
