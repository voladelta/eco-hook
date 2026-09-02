// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {ImmutableState} from "@uniswap/v4-periphery/src/base/ImmutableState.sol";

import {EcoBasketHook} from "../../src/EcoBasketHook.sol";
import {EcoPoolRegistry} from "../../src/EcoPoolRegistry.sol";
import {EcoVault} from "../../src/EcoVault.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {EasyPosm} from "../utils/libraries/EasyPosm.sol";

contract EcoBasketHookIntegrationTest is Test, BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;

    EcoBasketHook hook;
    EcoPoolRegistry registry;
    MockERC20 strategyToken;
    MockERC20 basketToken;
    PoolKey key;
    PoolId poolId;
    EcoVault vault;

    receive() external payable {}

    function setUp() public {
        deployArtifactsAndLabel();
        strategyToken = deployToken();
        basketToken = deployToken();
        vm.deal(address(this), 1_000_000 ether);

        uint160 flags =
            uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);
        address hookAddress = address(flags ^ uint160(0x45434f << 136));
        deployCodeTo(
            "EcoBasketHook.sol:EcoBasketHook", abi.encode(poolManager, address(this), address(this)), hookAddress
        );
        hook = EcoBasketHook(hookAddress);
        registry = hook.registry();
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(strategyToken)), 3000, 60, IHooks(address(hook)));
        poolId = key.toId();
        address[] memory basket = new address[](8);
        basket[0] = address(basketToken);
        for (uint256 i = 1; i < basket.length; ++i) {
            basket[i] = address(uint160(0xB000 + i));
        }
        (, address vaultAddress) = registry.preparePool(key, EcoPoolRegistry.Preset.Balanced, basket, 1 days, 7);
        vault = EcoVault(payable(vaultAddress));

        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);
        _addLiquidity(key);
    }

    function test_permissionsAreMinimalAndMatchAddress() public view {
        Hooks.Permissions memory permissions = hook.getHookPermissions();
        assertTrue(permissions.beforeInitialize);
        assertTrue(permissions.afterSwap);
        assertTrue(permissions.afterSwapReturnDelta);
        assertFalse(permissions.beforeSwap);
        assertFalse(permissions.beforeSwapReturnDelta);
        assertEq(uint160(address(hook)) & uint160((1 << 14) - 1), uint160(0x2044));
        assertEq(registry.approvedExecutor(), address(this));
        assertEq(vault.approvedExecutor(), address(this));
        assertEq(registry.orderHub().approvedExecutor(), address(this));
    }

    function test_unpreparedPoolInitializationIsRejected() public {
        PoolKey memory unprepared =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(strategyToken)), 500, 10, IHooks(address(hook)));
        vm.expectRevert();
        poolManager.initialize(unprepared, Constants.SQRT_PRICE_1_1);
    }

    function test_exactInputBuyCollectsOutputTokenAndAllocatesFee() public {
        uint256 beforeBalance = strategyToken.balanceOf(address(vault));
        BalanceDelta delta = _swap(true, -10 ether);
        uint256 fee = strategyToken.balanceOf(address(vault)) - beforeBalance;
        uint256 grossOutput = uint256(uint128(delta.amount1())) + fee;
        assertEq(fee, grossOutput * 75 / 10_000);
        (uint256 basketBudget, uint256 buyback, uint256 liquidity) = vault.allocations(address(strategyToken));
        assertEq(basketBudget, fee * 80 / 100);
        assertEq(buyback, fee * 10 / 100);
        assertEq(liquidity, fee - basketBudget - buyback);
        assertEq(registry.orderHub().nextOrderId(), 1, "callback must not create scheduled orders");

        uint256 executorBefore = strategyToken.balanceOf(address(this));
        vault.releaseMarketFunds(address(strategyToken), EcoVault.MarketAllocation.Buyback, buyback);
        assertEq(strategyToken.balanceOf(address(this)) - executorBefore, buyback);
    }

    function test_exactInputSellCollectsNativeQuoteAndAllocatesFee() public {
        uint256 beforeBalance = address(vault).balance;
        BalanceDelta delta = _swap(false, -10 ether);
        uint256 fee = address(vault).balance - beforeBalance;
        uint256 grossOutput = uint256(uint128(delta.amount0())) + fee;
        assertEq(fee, grossOutput * 25 / 10_000);
        (uint256 basketBudget, uint256 buyback, uint256 liquidity) = vault.allocations(address(0));
        assertEq(basketBudget, 0);
        assertEq(buyback, fee * 50 / 100);
        assertEq(liquidity, fee - buyback);
    }

    function test_bothExactOutputQuadrantsRejectWithoutStateChanges() public {
        uint256 strategyBefore = strategyToken.balanceOf(address(vault));
        uint256 nativeBefore = address(vault).balance;

        vm.expectRevert();
        _swap(true, 1 ether);
        vm.expectRevert();
        _swap(false, 1 ether);

        assertEq(strategyToken.balanceOf(address(vault)), strategyBefore);
        assertEq(address(vault).balance, nativeBefore);
        (uint256 basketBudget, uint256 buyback, uint256 liquidity) = vault.allocations(address(strategyToken));
        assertEq(basketBudget + buyback + liquidity, 0);
    }

    function test_exactOutputErrorNamesMissingPublishedGrossUpContract() public {
        vm.expectRevert(EcoBasketHook.ExactOutputUnsupportedWithoutPublishedHookrGrossUp.selector);
        vm.prank(address(poolManager));
        hook.afterSwap(
            address(0xCA11),
            key,
            SwapParams({zeroForOne: true, amountSpecified: 1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            BalanceDelta.wrap(0),
            Constants.ZERO_BYTES
        );
    }

    function test_poolStateAndVaultAccountingAreIsolated() public {
        MockERC20 secondStrategy = deployToken();
        PoolKey memory secondKey =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(secondStrategy)), 3000, 60, IHooks(address(hook)));
        address[] memory basket = new address[](1);
        basket[0] = address(basketToken);
        (, address secondVaultAddress) =
            registry.preparePool(secondKey, EcoPoolRegistry.Preset.Neutral, basket, 2 days, 4);
        poolManager.initialize(secondKey, Constants.SQRT_PRICE_1_1);
        _addLiquidity(secondKey);

        uint256 firstVaultBalance = strategyToken.balanceOf(address(vault));
        BalanceDelta delta = poolSwapRouter.swap{value: 10 ether}(
            secondKey,
            SwapParams({zeroForOne: true, amountSpecified: -10 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            Constants.ZERO_BYTES
        );
        assertGt(delta.amount1(), 0);
        assertGt(secondStrategy.balanceOf(secondVaultAddress), 0);
        assertEq(strategyToken.balanceOf(address(vault)), firstVaultBalance);
    }

    function test_directCallbacksRejectNonManagerCaller() public {
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.beforeInitialize(address(this), key, Constants.SQRT_PRICE_1_1);
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.afterSwap(
            address(this),
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            BalanceDelta.wrap(0),
            Constants.ZERO_BYTES
        );
    }

    function _swap(bool zeroForOne, int256 amountSpecified) private returns (BalanceDelta) {
        return poolSwapRouter.swap{value: zeroForOne ? 100 ether : 0}(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            Constants.ZERO_BYTES
        );
    }

    function _addLiquidity(PoolKey memory poolKey) private {
        int24 lower = TickMath.minUsableTick(poolKey.tickSpacing);
        int24 upper = TickMath.maxUsableTick(poolKey.tickSpacing);
        uint128 liquidity = 1_000 ether;
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1, TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), liquidity
        );
        positionManager.mint(
            poolKey,
            lower,
            upper,
            liquidity,
            amount0 + 1,
            amount1 + 1,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );
    }
}
