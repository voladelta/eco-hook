# Eco Basket architecture

We should build Eco Basket as a reusable protocol. We should also launch one token to prove that the protocol works.

The full hook should charge 0.75% on buys and 0.25% on sells. The first Hookr module should charge 1% on buys and no fixed sell fee.

Other creators can then use our factory to launch their own tokens. The factory will connect each token's canonical pool to the shared hook.

The first token is one use of the protocol. It is not the whole protocol.

## A hook belongs to a pool

A Uniswap v4 hook does not attach to an ERC-20 token. It attaches to a specific Uniswap v4 pool when someone creates that pool.

```text
Token: HOOKRECO
        │
        ▼
Pool: HOOKRECO / ETH
        │
        ▼
Hook: EcoBasketHook
```

Each pool can use only one hook. However, one hook contract can serve many pools.

The hook address forms part of the pool definition. Nobody can add or replace the hook after pool initialization. See [Uniswap v4 hooks][1].

## Recommended structure

```text
                    ECO PROTOCOL
                         │
          ┌──────────────┼──────────────┐
          ▼              ▼              ▼
   EcoLaunchFactory  EcoBasketHook   NarrativeOrderHub
          │              │              │
          │              │              └─ Executes scheduled buys
          │              │
          │              └─ Shared by all Eco pools
          │
          ├─ Creates HOOKRECO
          │      ├─ HOOKRECO / ETH pool
          │      ├─ EcoVault A
          │      └─ Basket: HOOKR + 4 tokens
          │
          ├─ Creates PONECO
          │      ├─ PONECO / ETH pool
          │      ├─ EcoVault B
          │      └─ Basket: PON + 6 tokens
          │
          └─ Creates AIECO
                 ├─ AIECO / ETH pool
                 ├─ EcoVault C
                 └─ Basket: AI anchor + 9 tokens
```

Uniswap v4 allows one hook contract to serve many pools. Therefore, `EcoBasketHook` can serve all 3 pools. Each pool has its own configuration and vault. See [Uniswap v4 hooks][1].

### Shared deployments

We deploy these contracts once:

- `EcoBasketHookV1`
- `EcoLaunchFactory`
- `EcoVault` implementation
- `EcoStaking` implementation
- `NarrativeOrderHub`
- `LiquidityManager`
- `EcoRouter`

### Creator deployments

Each launch creates:

- one plain ERC-20 strategy token
- one Uniswap v4 pool for the strategy token and quote token
- one dedicated `EcoVault`
- one staking and reward instance
- one immutable basket configuration

We do not redeploy the hook contract for each token.

## How creators launch an Eco token

A creator opens the Eco launch page and enters settings such as:

```text
Name:              Pon Ecosystem
Symbol:            PONECO
Quote asset:       ETH

Main anchor:       PON
Anchor weight:     40%

Satellite 1:       Token A — 15%
Satellite 2:       Token B — 15%
Satellite 3:       Token C — 10%
Satellite 4:       Token D — 10%
Satellite 5:       Token E — 10%

Fee preset:        Balanced
Strategy fees:
0.75% buy contribution
0.25% sell contribution

Buy allocation:
80% basket acquisition
10% PONECO buyback
10% PONECO liquidity reserve

Sell allocation:
50% PONECO buyback
50% PONECO liquidity reserve

TWAP runway:
7 days
```

The launch factory then runs this controlled sequence:

1. Deploy the PONECO token.
2. Deploy the PONECO `EcoVault`.
3. Validate the basket.
4. Register the configuration in `EcoBasketHook`.
5. Create the PONECO and ETH pool with `EcoBasketHook`.
6. Add and lock the initial liquidity.
7. Freeze the configuration.
8. Open trading.

The factory can expose this interface:

```solidity
function launch(EcoLaunchParams calldata params)
    external
    returns (
        address token,
        PoolId poolId,
        address vault
    );
```

Only the factory can register a new Eco pool.

## How the hook selects a basket

The shared hook stores information for each pool:

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

The hook does not need to store the detailed basket:

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

The pool's dedicated vault or configuration registry stores this information. This design keeps the hook small.

During a swap, the hook needs to answer 5 questions:

- which pool called the hook
- whether the transaction is a buy or sell
- what fee the hook must collect
- which vault must receive the fee
- how the vault must allocate the fee

The hook does not load 10 basket tokens during every trade.

## Keep the hook focused on swaps

The hook should do only the work that must happen during a swap:

```text
User trades PONECO
        │
        ▼
EcoBasketHook identifies the pool and direction
        │
        ├─ Buy contribution goes to the growth allocation
        ├─ Sell contribution goes to the resilience allocation
        └─ The remaining swap continues
```

After a buy, the PONECO `EcoVault` allocates the ETH:

```text
PONECO EcoVault receives ETH
        │
        ├─ 80% scheduled for basket purchases
        ├─ 10% scheduled for PONECO buyback
        └─ 10% retained for liquidity
```

After a sell, the vault keeps the contribution inside the PONECO market:

```text
PONECO EcoVault receives ETH
        │
        ├─ 50% scheduled for PONECO buyback
        └─ 50% retained for liquidity
```

The shared order executor later makes the scheduled purchases:

```text
NarrativeOrderHub
        │
        ├─ Buys PON over 7 days
        ├─ Buys Token A over 7 days
        ├─ Buys Token B over 7 days
        └─ Buys PONECO over 7 days
```

The hook must not make external purchases inside `beforeSwap` or `afterSwap`. Those purchases would make each trade expensive. They would also make each trade depend on several external pools.

The hook collects fees. The vault records allocations. The order hub buys tokens.

## Use a small hook-level strategy fee

The full Eco hook should charge 0.75% on buys and 0.25% on sells.

The first Hookr module can use a simpler 1% buy fee and no fixed sell fee. Large sells should use a depth-sensitive Surge Fee instead of a permanent 3% sell fee.

Do not use a 1% buy and 3% sell fee. Do not use a 3% fee in both directions. These fees make trading too expensive.

### Total trading costs

On 30 August 2026, an eligible ETH-paired Hookr market includes:

```text
0.30% base Uniswap liquidity provider fee
0.30% Hookr protocol fee
+ Eco strategy fee
```

Hookr applies its permanent 0.3% protocol fee to eligible ETH-pair swaps. Its current hook blocks do not add a permanent sell tax. See the [Hookr launchpad documentation][3].

The approximate costs are:

| Extra Eco fee | Total buy cost | Total sell cost | Flat-price round-trip loss | Price increase needed to break even |
| --- | ---: | ---: | ---: | ---: |
| 1% buy and 3% sell | 1.6% | 3.6% | 5.14% | 5.42% |
| 3% buy and 3% sell | 3.6% | 3.6% | 7.07% | 7.61% |
| 1% buy and no sell fee | 1.6% | 0.6% | 2.19% | 2.24% |
| 0.75% buy and 0.25% sell | 1.35% | 0.85% | 2.19% | 2.24% |
| 0.5% buy and 0.5% sell | 1.1% | 1.1% | 2.19% | 2.24% |

The table assumes that the market price does not change during the round trip. It applies the buy and sell costs in sequence.

These totals apply when Eco runs inside Hookr's eligible ETH-pair fee stack. An independent Eco pool does not pay Hookr's protocol fee unless an integration adds it.

These values exclude:

- price movement caused by the trade
- slippage
- maximal extractable value
- network fees
- temporary Anti-Snipe or Surge Fees

A market with 3% fees in both directions needs a price increase of more than 7.6%. Real trading costs can push this above 8%.

### A 3% sell fee does not protect the pool

A sell fee reduces the seller's proceeds. It does not stop the swap or remove its effect on the pool price.

For example, collect the fee from the ETH output of a $100 sale:

```text
Gross sell output:       $100.00
Eco sell fee:              $3.00
Seller receives:          $97.00
```

The whole swap still moves through the pool. Under the 80%, 10% and 10% buy allocation, the fee would fund:

```text
$2.40 → external basket tokens
$0.30 → ECO buyback
$0.30 → ECO liquidity reserve
```

Only $0.30 creates direct ECO buy pressure. Most of the fee buys external assets.

Collecting the fee in ECO does not solve this problem. It reduces the amount sold now, but the vault must later sell that ECO to buy basket assets.

The protocol must choose one result:

```text
Take the fee in ETH
    → funds basket purchases
    → does not reduce pool sell pressure

Take the fee in ECO
    → reduces immediate sell pressure
    → requires a later sale to fund the basket

Burn the ECO fee
    → reduces supply
    → produces no basket revenue
```

No fee can provide all 3 benefits at the same time.

A 3% sell fee also signals that entry is cheap but exit is expensive. This can reduce confidence in the canonical pool.

Anyone can create another Uniswap pool. Deep liquidity improves execution for large trades. See [Uniswap's explanation of automated market makers][4].

A high official-pool fee can move users and arbitrageurs to an untaxed pool. The canonical pool instead needs:

- deep liquidity
- a low fee
- good router support
- clear strategy benefits

### A 3% two-way fee can reduce revenue

The strategy earns fees from retained volume:

```text
strategy revenue = fee rate × retained trading volume
```

It does not earn the higher rate on unchanged volume.

Assume that buy and sell volumes are equal:

```text
1% buy and 3% sell
Average extra fee rate: 2%

3% buy and 3% sell
Average extra fee rate: 3%
```

At the same volume, the second option earns 50% more. However, it earns less if volume falls by more than one-third:

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

This can produce less revenue and smaller scheduled buys, despite the higher fee rate.

High fees also weaken price alignment between pools. Arbitrage becomes unprofitable until prices differ by more than all execution costs.

Uniswap v4 hooks can change swap deltas and support dynamic fees. The mechanism is possible, but it does not remove the economic cost. See the [Uniswap v4 hook implementation][5].

### Separate buy and sell allocations

Buy contributions should fund the product's main purpose:

```text
Buy fee: 0.75%

80% → anchor and satellite purchases over time
10% → ECO buyback and burn
10% → ECO liquidity reserve
```

A $1,000 buy provides:

```text
Eco contribution:          $7.50

Narrative basket:          $6.00
ECO buyback:               $0.75
Liquidity reserve:         $0.75
```

Sell contributions should strengthen the market being sold:

```text
Sell fee: 0.25%

50% → ECO buyback
50% → ECO protocol-owned liquidity
```

A $1,000 sell provides:

```text
Eco resilience fee:        $2.50

ECO buyback:               $1.25
Liquidity reserve:         $1.25
```

The rule is simple. Buys grow the basket. Sells strengthen the ECO market.

### Use Surge Fees for large trades

A $50 sale should not pay the same surcharge as a sale that consumes 15% of active liquidity.

The risk depends on trade size relative to current in-range depth. Use a dynamic fee for large trades:

```text
Small sell
    → normal liquidity provider fee
    → 0.25% Eco resilience fee

Large sell relative to depth
    → higher dynamic liquidity provider fee
    → extra fee goes to liquidity providers or protocol-owned liquidity
```

The first simulation can test these bands:

```text
Depth used below 0.25%  → no surge
Depth used from 0.25% to 1%  → small surge
Depth used from 1% to 3%  → medium surge
Depth used above 3%  → high surge, with a cap
```

These thresholds are not final. We must set them after simulation.

Hookr's Surge Fees block already changes the liquidity provider fee based on the in-range depth that a trade consumes. See the [Hookr launchpad documentation][3].

### Use fixed and immutable fee presets

Creators should select a reviewed preset. They should not set an arbitrary fee between 0% and 10%.

Arbitrary fees encourage low-quality launches to select the highest rate. They can also make users distrust all Eco launches.

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

This rule caps the total two-way Eco fee at one percentage point.

The pool must make its preset immutable when trading opens. Users must see the complete fee schedule before they buy. Hookr also makes pool rules immutable after opening. See the [Hookr launchpad documentation][3].

### Do not tax ERC-20 transfers

The fee belongs only in the canonical pool's hook. Do not add fee logic to `transfer()` or `transferFrom()`.

A transfer tax would also affect:

- staking deposits
- reward claims
- liquidity operations
- vault deposits
- router settlement
- direct transfers
- integrations with other protocols

Hookr's current launch tokens use a fixed supply. They have no owner, transfer tax, blacklist, pause or further minting. We should preserve these properties. See the [Hookr launchpad documentation][3].

Use hook accounting:

```text
Buy
    → take the quote contribution before the remaining quote enters the swap

Sell
    → take the quote contribution from the swap output
```

Uniswap v4 hook deltas support this model. See the [Uniswap v4 hook implementation][5].

### Exact-output trades must pay the fee

The fee must cover both exact-input and exact-output trades.

Hookr's current fee cuts apply to exact-input buys. Its exact-output sells avoid the current protocol fee by construction. See the [Hookr launchpad documentation][3].

The Eco hook must handle both sell paths:

```text
Exact-input sell
    → user specifies the ECO input
    → hook deducts the fee from the quote output

Exact-output sell
    → user specifies the quote output
    → hook increases the required ECO input to cover the fee
```

Otherwise, routers can select the path that avoids the fee.

The contract should support both paths. If it cannot, the hook must reject the unsupported exact-output direction. The official router must also reject it.

### Final fee choice

Use the Balanced preset for the full Eco hook:

```text
BASE MARKET COSTS
0.30% Uniswap liquidity provider fee
0.30% Hookr protocol fee on eligible ETH pairs

ECO STRATEGY FEES
0.75% buy contribution
0.25% sell resilience contribution

BUY ALLOCATION
80% basket purchases over time
10% ECO buyback
10% ECO liquidity reserve

SELL ALLOCATION
50% ECO buyback
50% ECO liquidity reserve

LARGE TRADES
Depth-sensitive Surge Fee
No permanent 3% exit tax
```

Use the Growth preset for the first version built inside Hookr's current model:

```text
1% buy contribution
No fixed sell contribution
Surge Fee for large sells
```

Do not use 1% buy and 3% sell or 3% in both directions as the standard. These settings favour the fee rate over volume, liquidity, price discovery and trust.

## Protect pool initialization

Anyone can normally ask the Uniswap v4 `PoolManager` to initialize a pool. The Eco hook must reject pools that our factory did not prepare.

The factory uses this sequence:

```text
Factory deploys token and vault
        │
        ▼
Factory computes expected PoolKey and PoolId
        │
        ▼
Factory registers a pending configuration
        │
        ▼
Factory initializes the exact pool
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
) external onlyFactory;

function beforeInitialize(
    address,
    PoolKey calldata key,
    uint160
) external returns (bytes4) {
    PoolId id = key.toId();

    if (pendingConfigHash[id] == bytes32(0)) {
        revert UnregisteredPool();
    }

    return this.beforeInitialize.selector;
}
```

This check stops another person from registering an unauthorised pool under the Eco name.

## Eco Basket cannot sit on top of Hookr

A Uniswap v4 pool cannot attach both hooks:

```text
HookrHook + EcoBasketHook
```

The pool can attach only one hook address. See [Uniswap v4 hooks][1].

Hookr currently launches markets with one shared hook. That hook provides selectable behaviours such as Anti-Snipe, Surge Fees, Auto Burn, LP Rewards and Nth-buy Pot.

We have 3 possible ways to work with Hookr.

### Path 1: Add Eco Basket as a Hookr block

```text
Hookr shared hook
    ├─ Anti-Snipe
    ├─ Surge Fees
    ├─ Auto Burn
    ├─ LP Rewards
    ├─ Nth-buy Pot
    └─ Eco Basket
```

The creator selects Eco Basket in the Hookr builder. They then configure:

- anchor token
- satellite tokens
- weights
- time-weighted average price duration
- reward mode
- fee preset

This path gives creators the best final Hookr experience. They can combine Eco Basket with compatible Hookr behaviours.

However, Hookr must add our behaviour to its composite hook, launcher, router, registry and frontend.

### Path 2: Publish a complete custom Eco hook

The creator selects `EcoBasketHook` as the pool's single custom hook.

The hook could support these behaviours internally:

```text
Eco Basket
+ Anti-Snipe
+ Surge Fees
+ optional Auto Burn
```

This design uses one complete composite hook. It does not add a second hook.

Hookr describes a marketplace for custom hooks. However, its V6.1 Builder is currently a source-only preview. It does not offer wallet deployment or a live address.

We should not depend on this self-service route being live on 30 August 2026. See the [Hookr custom hook builder][2].

### Path 3: Build an Eco launchpad

We deploy:

```text
EcoLaunchFactory
EcoBasketHook
EcoRouter
Eco frontend
```

The launcher uses the same Uniswap v4 `PoolManager` on Robinhood Chain. It does not depend on the current Hookr launcher.

This approach gives us control of:

- token creation
- basket validation
- fee routing
- vault creation
- time-weighted average price execution
- staking
- protocol-owned liquidity

The Eco launchpad can use tokens launched through Hookr as basket assets. However, Hookr must add an integration before it can treat these launches as official Hookr launches.

## Combine the independent and Hookr paths

The best practical choice combines paths 1 and 3.

### Build an independent reusable protocol

The contracts must not depend on one hardcoded token:

```text
EcoBasketHookV1
EcoLaunchFactory
EcoVault
NarrativeOrderHub
```

This design gives us a working system that we control.

### Prepare for a future Hookr module

We should keep the swap interface and configuration model compatible with a composite Hookr hook.

The central logic should use one interface for buys and sells:

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

Hookr could later add this module to its shared hook. It would not need to rewrite the vault and order system.

## Launch one canonical token

We should launch one canonical token through the same public factory that every future creator uses.

For example:

```text
Token:             HOOKRECO
Main anchor:       HOOKR
Satellites:        5 selected Hookr tokens

Strategy fees:
0.75% buy contribution
0.25% sell contribution

Buy allocation:
40% HOOKR TWAP
40% satellite TWAPs
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
- evidence that other creators can use the same infrastructure

The token must not have private or special behaviour. It must use the same contracts and validation rules as later launches.

## Do not create a protocol token yet

We do not initially need 3 token classes:

```text
Protocol governance token
+ canonical strategy token
+ user-created strategy tokens
```

We need only the infrastructure and its strategy tokens:

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

The infrastructure does not require a token. Protocol revenue can remain in ETH, `$HOOKR` or another disclosed quote asset.

A separate governance token would add complexity without improving the hook mechanism.

## Only the canonical pool produces Eco revenue

The token cannot force every trade to use the Eco pool. Someone could create other pools:

```text
PONECO / ETH with EcoBasketHook
PONECO / ETH without EcoBasketHook
PONECO / USDC without EcoBasketHook
```

Only trading through the canonical Eco pool produces Eco revenue.

The launch system should therefore:

- put all initial liquidity in the canonical pool that uses the hook
- lock that liquidity
- identify it as the official pool
- route the official frontend through it
- show rewards and metrics only for that pool
- avoid transfer restrictions in the token

We can make this promise:

> Every trade through the canonical Eco pool contributes to Eco. Buys fund the basket. Sells strengthen the token's home market.

We cannot claim that every transfer or trade pays the Eco strategy. Trades in other pools do not contribute.

## Final architecture decision

Build one shared hook for each version:

```text
ONE SHARED HOOK PER VERSION

EcoBasketHookV1
    ├─ Pool A configuration → Vault A
    ├─ Pool B configuration → Vault B
    ├─ Pool C configuration → Vault C
    └─ Pool N configuration → Vault N
```

Do not build a hardcoded hook for one token:

```text
Hardcoded HOOKRECO hook
    └─ Works for only one token
```

Do not build one upgradeable hook that lets its owner change the economics of every pool after launch.

Use immutable, versioned hook deployments:

```text
EcoBasketHookV1
EcoBasketHookV2
EcoBasketHookV3
```

Pools launched on V1 stay on V1. New pools can use a later version after review.

Each pool stores one reviewed fee preset. The factory makes that preset immutable when trading opens.

[1]: https://docs.uniswap.org/contracts/v4/concepts/hooks "Uniswap v4 hooks"
[2]: https://hookr.fun/builder "Build a custom hook with Hookr"
[3]: https://hookr.fun/docs "Hookr launchpad documentation"
[4]: https://blog.uniswap.org/what-is-an-automated-market-maker "How automated market makers use liquidity"
[5]: https://github.com/Uniswap/v4-core/blob/main/src/libraries/Hooks.sol "Uniswap v4 Hooks library"
