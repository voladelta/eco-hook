# Eco Basket architecture

We should build Eco Basket as a reusable protocol. We should also launch one token to prove that the protocol works.

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

Revenue:
80% basket acquisition
10% PONECO buyback
10% PONECO liquidity reserve

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

struct PoolConfig {
    address strategyToken;
    address quoteToken;
    address vault;
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

During a swap, the hook needs to answer 4 questions:

- which pool called the hook
- whether the transaction is a qualifying buy
- what fee the hook must collect
- which vault must receive the fee

The hook does not load 10 basket tokens during every trade.

## Keep the hook focused on swaps

The hook should do only the work that must happen during a swap:

```text
User buys PONECO
        │
        ▼
EcoBasketHook detects a qualifying buy
        │
        ├─ Normal swap continues
        │
        └─ Eco fee goes to PONECO EcoVault
```

After the swap, the PONECO `EcoVault` allocates the ETH:

```text
PONECO EcoVault receives ETH
        │
        ├─ 80% scheduled for basket purchases
        ├─ 10% scheduled for PONECO buyback
        └─ 10% retained for liquidity
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

The central logic should use a module interface:

```solidity
interface IEcoBasketModule {
    function onBuy(
        PoolId poolId,
        address quoteToken,
        uint256 quoteAmount
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

Revenue:
40% HOOKR TWAP
40% satellite TWAPs
10% HOOKRECO buyback
10% HOOKRECO liquidity

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

> Every trade through the canonical Eco pool funds more basket purchases over time.

We cannot claim that every transfer or trade pays the Eco strategy.

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

[1]: https://docs.uniswap.org/contracts/v4/concepts/hooks "Uniswap v4 hooks"
[2]: https://hookr.fun/builder "Build a custom hook with Hookr"
