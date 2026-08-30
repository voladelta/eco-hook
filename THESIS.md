# Eco Basket protocol

Buys grow the basket. Sells strengthen the token.

Eco Basket is a Uniswap v4 hook for tokens launched on hookr.fun. Creators select it at launch to turn trading fees into a flywheel for their chosen narrative. Buys fund scheduled TWAP purchases across the basket. Sells fund token buybacks and deeper liquidity. More activity feeds the loop and grows the pie for the whole basket.

Hookr handles the token launch and creates the Uniswap v4 pool. Eco Basket handles the fee strategy, basket and vault. Each pool keeps its own immutable rules.

## How one Eco token works

A creator chooses a main token and a basket of related tokens. The contracts call the main token the anchor.

The creator also chooses a reviewed fee preset and purchase schedule.

For example:

```text
Token:             HOOKRECO
Quote asset:       ETH
Main token:        HOOKR
Related tokens:    5 selected Hookr tokens
Fee preset:        Balanced
Purchase schedule: 7 days
```

Trading then creates a simple loop:

```text
Buy HOOKRECO
    │
    ├─ 80% of the Eco fee buys HOOKR and related tokens over time
    ├─ 10% buys back HOOKRECO
    └─ 10% builds HOOKRECO liquidity

Sell HOOKRECO
    │
    ├─ 50% of the Eco fee buys back HOOKRECO
    └─ 50% builds HOOKRECO liquidity
```

The hook collects the fee during the swap. The vault records its destination. The order executor makes scheduled purchases later.

This separation keeps user trades small and predictable. A trade does not depend on several external pools completing inside the same transaction.

## Core product decisions

### Publish one reviewed hook for each version

One `EcoBasketHook` can serve many pools. Each pool gets its own configuration and vault.

```text
EcoBasketHookV1
    ├─ Pool A configuration → Vault A
    ├─ Pool B configuration → Vault B
    ├─ Pool C configuration → Vault C
    └─ Pool N configuration → Vault N
```

We will deploy immutable hook versions:

```text
EcoBasketHookV1
EcoBasketHookV2
EcoBasketHookV3
```

Pools launched with V1 stay on V1. New Hookr launches can select a later version after review.

We will not build a hook that works only for `HOOKRECO`. We will also avoid one upgradeable hook that can change every pool after launch.

### Launch HOOKRECO as the first example

`HOOKRECO` will prove the shared protocol in production. It will launch through Hookr and select the same published Eco hook as later creators.

An example configuration is:

```text
Token:             HOOKRECO
Main token:        HOOKR
Related tokens:    5 selected Hookr tokens
Fee preset:        Balanced

Buy allocation:
40% HOOKR purchases over time
40% related-token purchases over time
10% HOOKRECO buyback
10% HOOKRECO liquidity

Sell allocation:
50% HOOKRECO buyback
50% HOOKRECO liquidity

Basket output:
60% staker rewards
40% redeemable reserve
```

The first token provides:

- a production canary
- a reference implementation
- the main dashboard example
- the first source of combined `$HOOKR` purchases
- evidence that other creators can use the same contracts

`HOOKRECO` must not have private or special behaviour.

### Do not create a governance token yet

The protocol does not initially need 3 token classes:

```text
Protocol governance token
+ canonical strategy token
+ creator strategy tokens
```

It needs only the protocol contracts and strategy tokens:

```text
Infrastructure:
Eco protocol contracts

First instance:
HOOKRECO

Later instances:
PONECO
AIECO
MEMEECO
...
```

Protocol revenue can remain in ETH, `$HOOKR` or another disclosed quote asset. A governance token would add complexity without improving the hook.

### Keep each strategy token simple

Each strategy token should be a plain, fixed-supply ERC-20 token. It should have no transfer tax, blacklist, pause or further minting.

The Eco fee belongs in the canonical pool's hook. A token transfer tax would also affect:

- staking deposits
- reward claims
- liquidity operations
- vault deposits
- router settlement
- direct transfers
- integrations with other protocols

Hookr's current launch tokens follow the same simple token model. See the [Hookr launchpad documentation][3].

## Fee design

### Use the Balanced preset for the full protocol

The full Eco hook should default to:

```text
ECO STRATEGY FEES
0.75% buy contribution
0.25% sell contribution

BUY ALLOCATION
80% basket purchases over time
10% strategy-token buyback
10% strategy-token liquidity

SELL ALLOCATION
50% strategy-token buyback
50% strategy-token liquidity

LARGE TRADES
Depth-sensitive Surge Fee
No permanent 3% exit tax
```

A $1,000 buy provides:

```text
Eco contribution:          $7.50

Narrative basket:          $6.00
Token buyback:             $0.75
Liquidity reserve:         $0.75
```

A $1,000 sell provides:

```text
Eco contribution:          $2.50

Token buyback:             $1.25
Liquidity reserve:         $1.25
```

Buys grow the chosen narrative. Sell fees stay inside the token's home market.

### Use Growth only if Hookr limits the first release

The target Hookr integration should use the Balanced preset. This needs correct fee accounting for buys, sells, exact-input swaps and exact-output swaps.

Hookr's current hook-block cuts apply to exact-input buys. If the first integration has the same limit, it should use this temporary preset:

```text
1% buy contribution
No fixed sell contribution
Depth-sensitive Surge Fee for large sells
```

The Growth preset fits Hookr's current buy-cut design. It avoids a permanent exit fee and still provides a clear basket budget.

We should move to Balanced only after the Hookr router and Eco hook pass all swap-mode tests.

### Offer reviewed fee presets

Creators should select a reviewed preset. They should not choose an arbitrary fee between 0% and 10%.

Arbitrary fees encourage low-quality launches to select high rates. They can also reduce trust in every Eco Basket pool.

Use these presets:

| Preset | Buy | Sell | Purpose |
| --- | ---: | ---: | --- |
| Growth | 1% | 0% | highest basket funding |
| Balanced | 0.75% | 0.25% | basket growth and market support |
| Neutral | 0.5% | 0.5% | equal contribution from each direction |
| High tax | not supported | not supported | excludes 3% configurations |

The contract should enforce this limit:

```solidity
buyStrategyFeeBps + sellStrategyFeeBps <= 100;
```

The Hookr launch flow must make the selected preset immutable when the pool opens. Users must see the full fee schedule before they sign and before they buy.

### Use Surge Fees for large trades

A small sale should not pay the same surcharge as a sale that consumes 15% of active liquidity.

The Surge Fee should rise with the share of in-range depth that a trade consumes. Extra fees should go to liquidity providers or protocol-owned liquidity.

Hookr already offers a Surge Fees block based on in-range depth. See the [Hookr launchpad documentation][3].

### Reject permanent 3% fees

Do not use 1% on buys and 3% on sells. Do not use 3% in both directions.

A 3% sell fee reduces the seller's proceeds but does not stop the sale. A 3% fee in both directions can reduce volume, arbitrage and market-maker participation.

See the [detailed fee calculations and rejected designs](#fee-calculations-and-rejected-designs).

## How creators use Eco Basket

A creator starts a new-token launch on Hookr. They choose the launch model, then select Eco Basket at the Hook step.

The creator enters the Eco settings as part of that launch:

```text
Name:              Hookr Ecosystem
Symbol:            HOOKRECO
Quote asset:       ETH

Main token:        HOOKR
Main weight:       40%

Related token 1:   Hookr token A — 15%
Related token 2:   Hookr token B — 15%
Related token 3:   Hookr token C — 10%
Related token 4:   Hookr token D — 10%
Related token 5:   Hookr token E — 10%

Fee preset:        Balanced
Purchase schedule: 7 days
```

Hookr then runs the launch:

1. Hookr validates the launch path, token settings and Eco configuration.
2. Hookr creates the token and fixes the launch terms.
3. Hookr and Eco compute the expected pool identity.
4. The Eco integration records the pool configuration and creates its vault.
5. Hookr opens the pool at launch or after a successful auction.
6. The pool opens with `EcoBasketHook` attached.
7. The Eco configuration becomes immutable.
8. Trading starts through Hookr's bounded router.

The exact contract calls depend on Hookr's integration interface. Eco must not create a second launchpad or replace Hookr's launch contracts.

## System architecture

```text
HOOKR LAUNCHPAD
    │
    ├─ Creates the token
    ├─ Opens the canonical pool
    ├─ Locks the launch liquidity
    └─ Attaches the selected EcoBasketHook
                    │
                    ▼
              ECO PROTOCOL
                    │
        ┌───────────┼──────────────┐
        ▼           ▼              ▼
 EcoBasketHook  EcoPoolRegistry  NarrativeOrderHub
        │           │              │
        │           │              └─ Executes scheduled buys
        │           │
        │           └─ Stores each pool's immutable rules and vault
        │
        ├─ HOOKRECO / ETH → EcoVault A → HOOKR + 5 tokens
        ├─ PONECO / ETH   → EcoVault B → PON + 5 tokens
        └─ AIECO / ETH    → EcoVault C → AI main token + 9 tokens
```

### Deploy shared contracts once

We deploy these contracts once for each protocol version:

- `EcoBasketHookV1`
- `EcoPoolRegistry`
- `EcoVaultFactory`
- `EcoVault` implementation
- `EcoStaking` implementation
- `NarrativeOrderHub`
- `LiquidityManager`

Eco should use Hookr's bounded router. It should not add another public trade route unless the hook needs one for a proven accounting constraint.

### Deploy isolated state for each launch

Hookr creates:

- one plain ERC-20 strategy token
- one Uniswap v4 pool for the strategy token and quote token

The Eco integration creates:

- one dedicated vault
- one staking and reward instance
- one immutable basket and fee configuration

The hook contract does not need a new deployment for each token.

### Give each contract one responsibility

The hook should do only the work that must happen during a swap:

```text
User trades PONECO
        │
        ▼
EcoBasketHook identifies the pool and direction
        │
        ├─ Buy contribution goes to the growth allocation
        ├─ Sell contribution goes to the market allocation
        └─ The remaining swap continues
```

The vault holds quote assets and records allocations. The order executor later makes basket purchases and buybacks.

The hook must not buy external tokens inside `beforeSwap` or `afterSwap`. That would make every trade expensive and dependent on several pools.

## Hookr strategy

### Integrate at the Hook step

Hookr is the launchpad. Its new-token flow covers intent, launch model, hook, token, price and fees, and review. A creator should select Eco Basket at the Hook step. See the [Hookr launch flow][6].

Hookr then owns:

- token creation
- the instant or auction launch path
- pool creation
- locked launch liquidity
- the canonical market record
- the bounded trade router

Eco owns:

- basket validation
- strategy fee accounting
- vault creation
- scheduled basket purchases
- token buybacks
- additional strategy-owned liquidity
- staking and rewards

### One pool cannot use 2 hooks

A Uniswap v4 pool can use only one hook address. It cannot attach both:

```text
HookrHook + EcoBasketHook
```

The same hook contract can still serve many pools. See [Uniswap v4 hooks][1].

Hookr lets creators compose behaviours into one hook. The pool opens with that hook already attached, and nobody can replace or retune it later. See [Hookr's explanation of hook blocks][7].

Eco Basket must therefore be a complete Hookr-compatible hook or a typed block within a Hookr-compiled hook. It cannot attach beside another hook.

### Publish Eco Basket as a selectable hook

A creator should be able to choose a reviewed Eco Basket version from Hookr's hook marketplace. The selected hook can include compatible launch behaviours:

```text
Eco Basket
+ Anti-Snipe
+ Surge Fees
+ optional Auto Burn
```

This is one composite hook, not a second hook.

The Hookr integration must register the hook and connect its launch parameters to the Eco pool registry. The launch review must show the basket, fee preset, schedule and hook address before the creator signs.

### Add a typed Eco block later

A later Hookr compiler could offer Eco Basket as a typed block. This would let creators combine it with other compatible blocks without deploying a second hook.

This route needs changes to Hookr's compiler, launcher, router, registry and frontend. The first integration does not need to wait for this more general interface.

### Do not build an Eco launchpad

Eco should not create tokens, choose opening prices or manage launch liquidity. Building those features again would duplicate Hookr and split the canonical launch record.

We can test the contracts with local fixtures and test launch adapters. Production launches must go through Hookr.

## Limits and open questions

### Only the canonical pool produces Eco revenue

The token cannot force every trade to use the Eco pool. Anyone can create other pools:

```text
PONECO / ETH with EcoBasketHook
PONECO / ETH without EcoBasketHook
PONECO / USDC without EcoBasketHook
```

Only trades through the canonical Eco pool contribute to its strategy.

The Hookr integration should therefore:

- put all initial liquidity in the canonical pool
- lock that liquidity
- identify it as the official pool
- route the official frontend through it
- show rewards and metrics only for that pool
- avoid transfer restrictions in the token

We can make this promise:

> Every trade through the canonical Eco pool contributes to Eco. Buys fund the basket. Sells strengthen the token's home market.

We cannot claim that every transfer or trade pays the Eco strategy.

### Surge Fee thresholds need simulation

The first simulation should test these bands:

```text
Depth used below 0.25%       → no surge
Depth used from 0.25% to 1% → small surge
Depth used from 1% to 3%    → medium surge
Depth used above 3%         → high surge, with a cap
```

These thresholds are proposals. We must test them against liquidity depth, trade sizes and router behaviour.

### Exact-output fees need implementation tests

The hook must not let exact-output trades avoid the Eco fee. The implementation must prove both trade paths before release.

### Launch after Hookr V6.1

Hookr will launch V6.1 first. Eco Basket will integrate and launch after that release.

Before implementation, we must confirm Hookr's deployed contracts, promoted release manifest and integration interface.

## Implementation reference

This section keeps the technical decisions needed for contract design and review.

### A hook belongs to a pool

A Uniswap v4 hook attaches to a pool, not an ERC-20 token:

```text
Token: HOOKRECO
        │
        ▼
Pool: HOOKRECO / ETH
        │
        ▼
Hook: EcoBasketHook
```

The hook address forms part of the pool definition. Nobody can add or replace it after pool initialization.

Each pool can use only one hook. One hook contract can serve many pools. See [Uniswap v4 hooks][1].

### Store one configuration for each pool

The shared hook stores the small amount of information needed during a swap:

```solidity
mapping(PoolId => PoolConfig) public poolConfigs;

enum FeePreset {
    Growth,
    Balanced,
    Neutral
}

struct PoolConfig {
    address strategyToken;
    address quoteToken;
    address vault;
    FeePreset feePreset;
    bool active;
}
```

The pool's dedicated vault or registry stores the detailed basket:

```solidity
struct BasketConfig {
    address anchor;
    address[] satellites;
    uint16[] weightsBps;
    uint32 twapDuration;
    uint16 rewardBps;
    uint16 reserveBps;
}
```

During a swap, the hook needs to answer 5 questions:

- which pool called the hook
- whether the trade is a buy or sell
- what fee the preset requires
- which vault receives the fee
- how the vault allocates the fee

The hook does not load every basket token during each trade.

### Use one module interface for all swaps

The central fee logic should accept both trade directions and both swap modes:

```solidity
enum SwapDirection {
    Buy,
    Sell
}

enum SwapMode {
    ExactInput,
    ExactOutput
}

interface IEcoBasketModule {
    function onSwap(
        PoolId poolId,
        address quoteToken,
        uint256 quoteAmount,
        SwapDirection direction,
        SwapMode mode
    ) external returns (uint256 strategyFee);
}
```

Hookr could later call this module without replacing the vault or order system.

### Cover exact-input and exact-output trades

The buy path takes its quote contribution before the remaining quote enters the swap.

```text
Buy
    → take the quote contribution
    → swap the remaining quote
```

The Eco hook must handle both sell paths:

```text
Exact-input sell
    → user specifies the strategy-token input
    → hook deducts the fee from the quote output

Exact-output sell
    → user specifies the quote output
    → hook increases the required strategy-token input to cover the fee
```

Otherwise, routers can select the path that avoids the fee.

The contract should support both paths. If it cannot, the hook must reject the unsupported direction. The official router must also reject it.

Hookr's current hook cuts apply to exact-input buys. Its exact-output sells avoid the current protocol fee by construction. See the [Hookr launchpad documentation][3].

Uniswap v4 hook deltas support this accounting model. See the [Uniswap v4 hook implementation][5].

### Protect pool initialization

Anyone can normally ask the Uniswap v4 `PoolManager` to initialize a pool. The Eco hook must reject pools that the approved Hookr launch flow did not prepare.

The Hookr integration should use this sequence:

```text
Hookr creates the token and fixes the launch terms
        │
        ▼
Hookr and Eco compute the expected PoolKey and PoolId
        │
        ▼
The approved Hookr adapter registers the Eco configuration and vault
        │
        ▼
Hookr initializes the exact pool at launch or auction migration
        │
        ▼
EcoBasketHook verifies the pending configuration
        │
        ▼
Pool becomes active
```

The hook can enforce the sequence as follows:

```solidity
mapping(PoolId => bytes32) public pendingConfigHash;

function preparePool(
    PoolKey calldata key,
    address vault,
    bytes32 configHash
) external onlyHookrAdapter;

function beforeInitialize(
    address,
    PoolKey calldata key,
    uint160
) external onlyPoolManager returns (bytes4) {
    PoolId id = key.toId();

    if (pendingConfigHash[id] == bytes32(0)) {
        revert UnregisteredPool();
    }

    delete pendingConfigHash[id];
    poolConfigs[id].active = true;

    return this.beforeInitialize.selector;
}
```

This check stops another person from registering an unauthorised pool under the Eco name. The adapter needs a narrow interface that Hookr can call during an instant launch or auction migration.

An instant launch should prepare and activate the Eco pool in one transaction. A failed step should revert the whole launch.

An auction needs an explicit pending state because the pool opens later. A failed auction must cancel or expire its pending Eco configuration. The vault must not accept strategy funds until the pool becomes active.

### Fee calculations and rejected designs

On 30 August 2026, an eligible ETH-paired Hookr market includes:

```text
0.30% base Uniswap liquidity provider fee
0.30% Hookr protocol fee
+ Eco strategy fee
```

Hookr does not add a permanent sell tax through its current hook blocks. See the [Hookr launchpad documentation][3].

The approximate costs are:

| Extra Eco fee | Total buy cost | Total sell cost | Flat-price round-trip loss | Price increase needed to break even |
| --- | ---: | ---: | ---: | ---: |
| 1% buy and 3% sell | 1.6% | 3.6% | 5.14% | 5.42% |
| 3% buy and 3% sell | 3.6% | 3.6% | 7.07% | 7.61% |
| 1% buy and no sell fee | 1.6% | 0.6% | 2.19% | 2.24% |
| 0.75% buy and 0.25% sell | 1.35% | 0.85% | 2.19% | 2.24% |
| 0.5% buy and 0.5% sell | 1.1% | 1.1% | 2.19% | 2.24% |

The table assumes that the market price does not change during the round trip. It applies the buy and sell costs in sequence.

These totals are proposals for Eco inside Hookr's eligible ETH-pair fee stack. They do not describe a live Eco Basket launch.

The values exclude:

- price movement caused by the trade
- slippage
- maximal extractable value
- network fees
- temporary Anti-Snipe or Surge Fees

A market with 3% fees in both directions needs a price increase of more than 7.6%. Real trading costs can push this above 8%.

#### A high sell fee does not stop a sale

For example, collect a 3% fee from the ETH output of a $100 sale:

```text
Gross sell output:       $100.00
Eco sell fee:              $3.00
Seller receives:          $97.00
```

The whole swap still moves through the pool. Under an 80%, 10% and 10% allocation, the fee would fund:

```text
$2.40 → external basket tokens
$0.30 → strategy-token buyback
$0.30 → strategy-token liquidity
```

Only $0.30 creates direct buy pressure for the strategy token. Most of the fee buys external assets.

Collecting the fee in the strategy token delays the pressure but does not remove it. The vault must later sell those tokens to fund basket purchases.

The protocol must choose one result:

```text
Take the fee in ETH
    → funds basket purchases
    → does not reduce pool sell pressure

Take the fee in the strategy token
    → reduces immediate sell pressure
    → requires a later sale to fund the basket

Burn the strategy-token fee
    → reduces supply
    → produces no basket revenue
```

No fee provides all 3 benefits at the same time.

A high official-pool fee can also move users and arbitrageurs to an untaxed pool. Deep liquidity improves execution for large trades. See [Uniswap's explanation of automated market makers][4].

#### A high two-way fee can reduce revenue

The strategy earns fees from retained volume:

```text
strategy revenue = fee rate × retained trading volume
```

Assume that buy and sell volumes are equal:

```text
1% buy and 3% sell
Average extra fee rate: 2%

3% buy and 3% sell
Average extra fee rate: 3%
```

At the same volume, the second option earns 50% more. It earns less if volume falls by more than one-third:

```text
3% × 66.7% volume ≈ 2% × 100% volume
```

High fees can reduce:

- speculative trading
- arbitrage
- market-maker participation
- router competitiveness
- market discovery
- fee-generating activity

They also weaken price alignment between pools. Arbitrage becomes unprofitable until prices differ by more than all execution costs.

Uniswap v4 hooks can change swap deltas and support dynamic fees. The mechanism is possible, but it does not remove the economic cost. See the [Uniswap v4 hook implementation][5].

## Delivery sequence

Use the [Hookr integration order](PLAN.md) to move from this thesis into implementation.

[1]: https://docs.uniswap.org/contracts/v4/concepts/hooks "Uniswap v4 hooks"
[3]: https://hookr.fun/docs "Hookr launchpad documentation"
[4]: https://blog.uniswap.org/what-is-an-automated-market-maker "How automated market makers use liquidity"
[5]: https://github.com/Uniswap/v4-core/blob/main/src/libraries/Hooks.sol "Uniswap v4 Hooks library"
[6]: https://hookr.fun/launch "Launch a programmable market on Hookr"
[7]: https://hookr.fun/learn/uniswap-v4-hooks "How Hookr composes Uniswap v4 hooks"
