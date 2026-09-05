# Architecture and safety boundaries

Hookr remains responsible for token creation, the canonical pool, launch liquidity, and routing. Eco Basket starts at the external-hook boundary.

The Hookr V6 candidate keeps Hookr's modular root as the pool hook. `EcoBasketModuleV1` is a
read-only typed policy under that root; direction-bound `EcoBasketClaimStrategyV1` contracts own
stateful native-quote claim accounting and settle only to one `EcoBasketModuleVault`. This candidate
is separate from the standalone hook described below and still requires Hookr profile and SDK
admission.

Pool preparation is one transaction before initialization. It validates native/token orientation, one of three fee presets, one to eight unique basket tokens, and a bounded schedule. It creates the isolated vault before any callback. PoolManager initialization activates the prepared record. No later function can change it.

The hook constructor also fixes one product-owned executor address. The registry passes the same address to the order hub and every vault. The address is an explicit trusted custody boundary. It cannot change configuration or redirect a transfer. All authorized releases go only to this address.

`afterSwap` has constant work. It reads one pool record, calculates one fee, calls `PoolManager.take`, and records three allocation counters at most. BaseHook rejects any direct callback caller other than the immutable PoolManager. The callback ignores its sender and hook data.

The vault holds the asset that the pool produced. Exact-input buys therefore fund accounting with the strategy token. Buyback and liquidity releases decrement their recorded allocation before transferring native or standard ERC20 funds to the fixed executor. Basket releases require a due scheduled order. This source does not define the executor's conversion, slippage, routing, or market actions.

Scheduled orders are bounded accounting records. Only the fixed executor can schedule or release them. The schedule starts at the current block time. The order hub advances state before it asks the vault to transfer due funds. Permissionless expiry closes stale orders after the complete schedule and a 30-day grace period, then restores all unreleased accounting to the vault basket allocation.
