# Eco / Hookr local integration

This suite deploys the current Hookr contracts and Eco's module candidate in a local EVM. It uses
the real PoolManager, catalog, StackRegistry, V6 root, V5 coordinator, Native Mechanics V2, Hookr
router/quoter, and treasury forwarder. The root is mined with CREATE2 for `0x28cc` flags; all
registration and sealing use the contracts' normal owner functions.

The profile is a proposed Eco-bearing test profile. It is not Hookr's deployed profile or production
approval. No private Hookr implementation is copied into Eco's repository.

## Reproduce

Use the checkout at the commit in `../hookr/current-review-source.json`, currently
`486a8e62767977c06bb82db43e73e816e0545038`, with its exact submodules:

```sh
git -C ../hookr-modular-hooks submodule update --init --recursive
./scripts/test-hookr-local.sh -vv
```

For a different checkout location:

```sh
HOOKR_REVIEW_CHECKOUT=/path/to/hookr-modular-hooks ./scripts/test-hookr-local.sh -vv
```

The runner verifies the Hookr commit, source hashes, and submodule revisions before compiling.
This project uses Solidity 0.8.26, via IR, 200 optimizer runs, Cancun, and IPFS metadata, with
Hookr's pinned v4-core and forge-std. Eco's existing standalone 0.8.30 build remains separate.
Fuzzing uses 64 runs and seed `0xec0`.

Run all Eco checks, including this suite, with:

```sh
HOOKR_REVIEW_CHECKOUT=../hookr-modular-hooks ./scripts/check.sh
```

CI without access to the private Hookr checkout runs the standalone checks and local ABI pins;
that is not a substitute for this integration command. Builds are placed in this project's ignored
`out/` and `cache/` directories.

## Launcher prototype

`src/EcoHookrTestLauncher.sol` is restricted to its deploying operator. Its constructor creates
Eco's registry with the launcher as the immutable approved adapter. It demonstrates:

1. Deriving a pool key from the active Hookr kernel; for a new token, predicting its CREATE2 address
   with the launcher as `expectedCreator` before preparation.
2. Preparing Eco and obtaining its canonical policy config.
3. Binding native config to that pool, the current launcher share tier, and the coordinator treasury.
4. Selecting both modules and opening through the real coordinator.
5. Forwarding an optional new-token creator-buy output to the test operator. The founding LP fee
   recipient remains a separate caller-supplied field.

Preparation and market opening are atomic when invoked together. A failed opening rolls back the
new preparation and token deployment. A prior standalone preparation survives a failed opening
and can be reused with the identical Eco commitment; changing preset, basket, schedule, or executor
commitment is rejected. Native configuration can be rebuilt for a changed creator tier before
opening because it is not frozen until stack admission.

The prototype is not a multi-user launcher contract or a published SDK. User intent authorization,
production deployment parameters, and product-facing preparation recovery still require agreement
with Hookr. It has no production deployment script.

## What the tests establish

| Area | Evidence |
| --- | --- |
| Admission | A new profile can admit Eco with Native Mechanics. Catalog registration cannot expand a sealed native-only profile. Eco-only selections fail. |
| Identity | Predicted token, pool key, pool ID, frozen stack/config hashes, creator, vault, and strategy bindings agree. |
| Fees | Growth, Balanced, and Neutral cover exact-input/output buys/sells with independent fee arithmetic and final wallet checks. |
| Quotes | The real Hookr quoter matches router execution and rolls back pool price, claims, native accounting, pot state, and token balances. |
| Settlement | Actual ERC-6909 claims are minted by the hook, burned through PoolManager unlock, and paid to the fixed Eco vault. Split settlements conserve allocations. |
| Composition | Native surge, burn, LP donation, pot, royalty, and treasury claims coexist with Eco's separate liabilities. |
| Boundaries | Failed launch rollback, preparation retry, changed Eco intent, creator-tier refresh, guard expiry, and noncanonical price-limit rejection are exercised. |

Native Mechanics counts at most one qualifying pot buy per block. Exact-output buys are rejected
during its guard. Eco's specified-quote buy fee also requires the canonical full-fill price limit,
even with all optional native fees disabled.

The fixture's catalog gas bounds are 1,000,000 for Native Mechanics and 400,000 for Eco; stack gas
is their sum. Native registration caps cover the tested configurations, and Eco's caps are 100 bps
on either quote leg, zero subject take, with Native Mechanics listed as a required module key.
These are test admission parameters, not recommended production gas/cap settings. The exact
registration structures and profile construction live in `test/HookrLocalFixture.sol`.

## Pinned fork

The optional fork suite uses the deployed PoolManager, Universal Router, and Permit2 at block
58,416,400 on chain 4663. Addresses, runtime hashes, and the block identity are in
[`fork-source.json`](fork-source.json). It deploys a fresh Eco-bearing Hookr graph only inside the
fork. Every operation is simulated; it does not send transactions to the network.

```sh
HOOKR_FORK_RPC_URL=https://rpc.mainnet.chain.robinhood.com \
  ./scripts/test-hookr-local.sh --match-contract EcoHookrForkTest -vv
```

Use an RPC with historical state for the pinned block. Without `HOOKR_FORK_RPC_URL`, fork tests
are explicitly skipped. The selected Universal Router is the runtime identified in Hookr's fork
evidence, not an assertion that its other published candidate has identical behavior. Its verified
`IV4Router` tuples include `minHopPriceX36`; encoders for older tuples must not be reused.

The fork covers all four Balanced swap quadrants through Universal Router, Permit2-funded sells,
third-party recipients, exact-output native refunds, claim settlement, and rejection of nonempty
untrusted hook data. A same-state comparison checks that Universal Router does not participate in
the native pot while Eco's fee still applies.

## Review packet and limits

Validation on 2026-09-09 used Foundry 1.7.1 (`4072e48705af9d93e3c0f6e29e93b5e9a40caed8`):

- 16 local integration tests passed, including 64 fuzz cases with seed `0xec0`.
- All three pinned-fork tests passed.
- The full repository check passed: 46 existing Solidity tests, 14 manifest-validator tests,
  source checks, formatting, build/size checks, and Slither's high-severity gate. Slither reports
  existing findings below that gate; the prototype is not independently audited.
- The no-RPC path explicitly skips the fork suite.

The local gas report for the settlement and swap-matrix suites recorded these per-call ranges:

| Call | Minimum gas | Maximum gas |
| --- | ---: | ---: |
| Hookr router `exactInput` | 577,855 | 1,072,804 |
| Hookr router `exactOutput` | 535,608 | 616,588 |
| Eco strategy `settleClaims` | 91,268 | 179,757 |
| Prototype `openExisting`, including Eco preparation | 3,860,399 | 4,913,767 |

Reproduce with:

```sh
./scripts/test-hookr-local.sh \
  --match-contract 'EcoHookr(Settlement|SwapMatrix)Test' --gas-report
```

These are observed EVM execution costs across the test fixtures, not transaction gas limits or
worst-case bounds. They do not measure chain-specific L1 data fees. The fixture uses one liquidity
range and bounded swap sizes; it does not establish arbitrary tick-crossing, liquidity exhaustion,
every native configuration, or multi-hop routing behavior.

Hookr maintainers still need to approve the module, production registration caps and gas budgets,
and an Eco-bearing profile/deployment. This suite supplies a reproducible candidate and integration
evidence, not that approval or an independent audit.
