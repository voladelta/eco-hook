// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {EcoPoolRegistry} from "./EcoPoolRegistry.sol";
import {EcoVault} from "./EcoVault.sol";

/// @notice A non-upgradeable multi-pool Eco Basket fee hook.
contract EcoBasketHook is BaseHook {
    using PoolIdLibrary for PoolKey;

    error ExactOutputUnsupportedWithoutPublishedHookrGrossUp();
    error PoolNotActive(PoolId poolId);
    error InvalidOutputDelta(int128 outputDelta);

    EcoPoolRegistry public immutable registry;

    constructor(IPoolManager manager, address approvedAdapter, address approvedExecutor) BaseHook(manager) {
        registry = new EcoPoolRegistry(address(this), approvedAdapter, approvedExecutor);
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _beforeInitialize(address, PoolKey calldata key, uint160) internal override returns (bytes4) {
        registry.activatePool(key);
        return BaseHook.beforeInitialize.selector;
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        // PR #3 does not publish the router and quote contract needed to gross up exact-output swaps safely.
        if (params.amountSpecified >= 0) revert ExactOutputUnsupportedWithoutPublishedHookrGrossUp();

        PoolId poolId = key.toId();
        EcoPoolRegistry.PoolConfig memory config = registry.config(poolId);
        if (!config.active) revert PoolNotActive(poolId);

        bool buy = params.zeroForOne;
        int128 outputDelta = buy ? delta.amount1() : delta.amount0();
        if (outputDelta <= 0) revert InvalidOutputDelta(outputDelta);
        uint256 fee = uint256(uint128(outputDelta)) * (buy ? config.buyFeeBps : config.sellFeeBps) / 10_000;
        if (fee == 0) return (BaseHook.afterSwap.selector, 0);

        Currency fundingCurrency = buy ? key.currency1 : key.currency0;
        poolManager.take(fundingCurrency, config.vault, fee);
        EcoVault(payable(config.vault)).recordFee(Currency.unwrap(fundingCurrency), fee, buy);
        return (BaseHook.afterSwap.selector, int128(uint128(fee)));
    }
}
