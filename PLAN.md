# Eco Basket delivery plan

## Current state

Eco Basket V1 has a verified source implementation at commit `a5f9ebd3da28911bc8d99194126869cab38eca64`.

Complete work:

- reusable non-upgradeable hook for many pools
- one-time pool preparation and immutable activation
- reviewed Growth, Balanced and Neutral fee presets
- isolated vault and allocation accounting for each pool
- bounded basket order records and fixed-recipient fund release
- immutable Hookr adapter and Eco executor boundaries
- exact-input buy and sell tests through a real PoolManager
- atomic rejection of both exact-output directions
- Hookr external-hook V2 source manifest pinned to the verified source
- full local checks, including 28 Forge tests, manifest validation and static analysis

The source is not deployed, audited, approved by Hookr or submitted for listing.

## Current Hookr compatibility assessment

The current assessment is pinned to
`Hookr-fun/hookr-modular-hooks@486a8e62767977c06bb82db43e73e816e0545038`. The release uses a
V6 shared root, V5 coordinator, and mandatory Native Mechanics V2. It does not admit Eco's
standalone hook or include Eco in the deployed sealed profile. The earlier review at `aa5c93b...`
is historical; its bundled SDK and handoff packet have been removed upstream.

The selected integration direction is a typed Eco policy so Hookr remains the pool's only
hook. An external Eco root is out of scope. The Eco-side candidate now implements a typed policy,
direction-bound stateful claim strategies, and native-quote vault settlement. Hookr still needs to
agree and implement profile admission, current client encoding, transaction ordering, and real-root
tests with mandatory Native Mechanics. The full finding and pinned evidence are in
[`docs/hookr-current-compatibility-review.md`](docs/hookr-current-compatibility-review.md).

## Phase 1: request Hookr source review

Next actions:

1. Give Hookr the pinned manifest, source commit and test evidence.
2. Agree Eco's read-only policy and stateful claim strategies alongside mandatory Native Mechanics.
3. Record Hookr review findings and required source changes in this repository.
4. Do not claim Hookr approval until Hookr gives explicit approval for the pinned source.

Exit condition: Hookr accepts the source-review package or gives a fixed list of required changes.

## Phase 2: agree the production interfaces

Agree these items with Hookr before adding production integration code:

- new-token and existing-asset launcher calls and adapter authority
- failed or abandoned preparation and launch retry behavior
- canonical pool identity and activation order
- approved router and quoter behavior
- exact-output gross-up and prefund settlement
- final payer, recipient and refund rules
- deployment, runtime-code and hook-address evidence
- stateful-module admission, settlement, and compatibility with Hookr native blocks

The current release publishes contracts and integration guides for its own admitted modular root.
Its policy ABI matches Eco's candidate, but no Eco profile or client preparation path is supplied.
Do not treat shared-root canary evidence as Eco compatibility. Creator-tier revenue, native guard
behavior, combined fee caps, and router-specific settlement require current-release tests.

Exit condition: Hookr and Eco have one written interface package with exact ABIs, addresses or address-discovery rules, transaction order, failure behavior and test requirements.

## Phase 3: implement the Hookr launch path

After Phase 2 is complete:

1. Implement the narrow Hookr adapter against the agreed interface.
2. Test new-token launch as one atomic prepare, initialize and activate operation where supported.
3. Test existing-asset opening, failed launch rollback, and retry of a previously prepared pool.
4. Add the approved router and quoter policy.
5. Implement and test quote-funded buys and both exact-output directions if the agreed settlement model supports them.
6. Keep unsupported swap modes rejected until their full settlement path passes.
7. Test final wallet balances, refunds and vault balances for all four swap quadrants.

Exit condition: the Hookr launch and routing test matrix passes without a fee bypass or stranded balance.

## Phase 4: complete execution and security readiness

Before a deployment with real value:

1. Define and review the immutable executor deployment and operating policy.
2. Implement the approved external basket purchase, buyback and liquidity operations outside hook callbacks.
3. Add slippage, minimum-output, deadline and replay controls.
4. Run stateful fuzz tests, accounting invariants, target-chain fork tests and gas measurements.
5. Simulate fee presets, basket schedules and proposed Surge Fee thresholds against expected liquidity.
6. Obtain an independent contract audit and repair all release-blocking findings.
7. Prepare monitoring, spending limits, incident actions and public risk disclosures.
8. Produce the final deployment manifest and reproduce its bytecode from the pinned source.

Exit condition: the audit, fork tests, execution controls and deployment evidence pass the release review.

## Phase 5: publish and launch

1. Publish the reviewed Eco Basket hook for selection on Hookr.
2. Launch `HOOKRECO` through Hookr with Eco Basket selected.
3. Run `HOOKRECO` as a production canary with strict spending limits.
4. Review canary accounting, execution quality, volume and operational events.
5. Open the reviewed hook to other Hookr creators only after the canary review passes.
6. Expand adoption only within the reviewed Eco-bearing profile and tested configuration limits.

## Current release blockers

- Hookr admits sealed shared roots; Eco V1 is a different standalone hook.
- The V5 coordinator has no Eco preparation step, and the old bundled SDK has been removed.
- Hookr must register the Eco policy module and admit it in a newly reviewed sealed root profile.
- Native Mechanics V2 must remain selected and satisfy creator-tier and treasury admission rules.
- Hookr's router/quoter evidence covers its admitted configuration, not Eco settlement.
- The standalone hook rejects exact-output swaps and collects buy fees in the strategy token.
  The module candidate supports all four policy quadrants in native quote, subject to Hookr's guard,
  aggregate fees, and real-root settlement verification.
- The repository defines the immutable executor custody boundary but not its external market operations.
- The contracts are unaudited and have no production deployment or Hookr approval.

The final decision remains:

> Hookr creates each token and its canonical pool. The creator selects Eco Basket during the Hookr launch. Eco Basket then manages the pool's fee strategy, basket and vault.
