// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {EcoPoolRegistry} from "../../src/EcoPoolRegistry.sol";
import {EcoVault} from "../../src/EcoVault.sol";
import {NarrativeOrderHub} from "../../src/NarrativeOrderHub.sol";

contract EcoPoolRegistryTest is Test {
    using PoolIdLibrary for PoolKey;

    EcoPoolRegistry registry;
    MockERC20 fundingToken;
    PoolKey key;
    PoolId poolId;
    address[] basket;

    receive() external payable {}

    function setUp() public {
        fundingToken = new MockERC20("Funding", "FUND", 18);
        registry = new EcoPoolRegistry(address(this), address(this), address(this));
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(fundingToken)), 3000, 60, IHooks(address(this)));
        poolId = key.toId();
        basket.push(address(0x2000));
        basket.push(address(0x3000));
    }

    function test_reviewedPresetsStayAtOrBelowOnePercent() public view {
        for (uint256 i; i < 3; ++i) {
            (uint16 buyFeeBps, uint16 sellFeeBps) = registry.feesForPreset(EcoPoolRegistry.Preset(i));
            assertLe(buyFeeBps + sellFeeBps, 100);
        }
        assertEq(_fees(EcoPoolRegistry.Preset.Growth), bytes32(uint256(100) << 16));
        assertEq(_fees(EcoPoolRegistry.Preset.Balanced), bytes32((uint256(75) << 16) | 25));
        assertEq(_fees(EcoPoolRegistry.Preset.Neutral), bytes32((uint256(50) << 16) | 50));
    }

    function test_prepareThenActivateFreezesPoolConfigurationAndExecutor() public {
        EcoVault vault = _prepare();
        EcoPoolRegistry.PoolConfig memory beforeActivation = registry.config(poolId);
        assertTrue(beforeActivation.prepared);
        assertFalse(beforeActivation.active);
        assertEq(beforeActivation.vault, address(vault));
        assertEq(vault.approvedExecutor(), address(this));
        assertEq(registry.orderHub().approvedExecutor(), address(this));

        registry.activatePool(key);
        EcoPoolRegistry.PoolConfig memory active = registry.config(poolId);
        assertTrue(active.active);
        assertEq(active.buyFeeBps, 75);
        assertEq(active.sellFeeBps, 25);

        vm.expectRevert(abi.encodeWithSelector(EcoPoolRegistry.PoolAlreadyPrepared.selector, poolId));
        registry.preparePool(key, EcoPoolRegistry.Preset.Growth, basket, 2 days, 4);
        vm.expectRevert(abi.encodeWithSelector(EcoPoolRegistry.PoolAlreadyActive.selector, poolId));
        registry.activatePool(key);
    }

    function test_onlyImmutableAdapterCanPrepare() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(EcoPoolRegistry.OnlyApprovedAdapter.selector, address(0xBAD)));
        registry.preparePool(key, EcoPoolRegistry.Preset.Balanced, basket, 1 days, 7);
    }

    function test_executorMustBeNonzero() public {
        vm.expectRevert(EcoPoolRegistry.InvalidDependency.selector);
        new EcoPoolRegistry(address(this), address(this), address(0));
    }

    function test_basketAndScheduleBoundsAreEnforcedBeforeVaultCreation() public {
        address[] memory tooMany = new address[](9);
        for (uint256 i; i < tooMany.length; ++i) {
            tooMany[i] = address(uint160(0x4000 + i));
        }
        vm.expectRevert(abi.encodeWithSelector(EcoPoolRegistry.InvalidBasketLength.selector, 9));
        registry.preparePool(key, EcoPoolRegistry.Preset.Balanced, tooMany, 1 days, 7);

        vm.expectRevert(EcoPoolRegistry.InvalidOrderSchedule.selector);
        registry.preparePool(key, EcoPoolRegistry.Preset.Balanced, basket, 1 days, 33);
    }

    function test_vaultAllocationPreservesEveryRemainder() public {
        EcoVault vault = _prepare();
        vault.recordFee(address(fundingToken), 101, true);
        (uint256 basketAmount, uint256 buyback, uint256 liquidity) = vault.allocations(address(fundingToken));
        assertEq(basketAmount, 80);
        assertEq(buyback, 10);
        assertEq(liquidity, 11);

        vault.recordFee(address(0), 101, false);
        (basketAmount, buyback, liquidity) = vault.allocations(address(0));
        assertEq(basketAmount, 0);
        assertEq(buyback, 50);
        assertEq(liquidity, 51);
    }

    function test_hostileCallerCannotScheduleOrZeroBasketBudget() public {
        EcoVault vault = _prepare();
        vault.recordFee(address(fundingToken), 101, true);

        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(EcoVault.OnlyExecutor.selector, address(0xBAD)));
        vault.scheduleBasketOrders(address(fundingToken));

        (uint256 basketAmount,,) = vault.allocations(address(fundingToken));
        assertEq(basketAmount, 80);
        assertEq(vault.scheduledBasket(address(fundingToken)), 0);
    }

    function test_executorCanReleaseOnlyRecordedMarketFundsToItself() public {
        EcoVault vault = _prepare();
        vault.recordFee(address(fundingToken), 101, true);
        fundingToken.mint(address(vault), 101);

        uint256 tokenBefore = fundingToken.balanceOf(address(this));
        vault.releaseMarketFunds(address(fundingToken), EcoVault.MarketAllocation.Buyback, 10);
        vault.releaseMarketFunds(address(fundingToken), EcoVault.MarketAllocation.Liquidity, 11);
        assertEq(fundingToken.balanceOf(address(this)) - tokenBefore, 21);

        vault.recordFee(address(0), 101, false);
        vm.deal(address(vault), 101);
        uint256 nativeBefore = address(this).balance;
        vault.releaseMarketFunds(address(0), EcoVault.MarketAllocation.Buyback, 50);
        vault.releaseMarketFunds(address(0), EcoVault.MarketAllocation.Liquidity, 51);
        assertEq(address(this).balance - nativeBefore, 101);
    }

    function test_hostileCallerAndOverdrawCannotReleaseMarketFunds() public {
        EcoVault vault = _prepare();
        vault.recordFee(address(fundingToken), 101, true);
        fundingToken.mint(address(vault), 101);

        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(EcoVault.OnlyExecutor.selector, address(0xBAD)));
        vault.releaseMarketFunds(address(fundingToken), EcoVault.MarketAllocation.Buyback, 1);

        vm.expectRevert(abi.encodeWithSelector(EcoVault.InvalidReleaseAmount.selector, 11, 10));
        vault.releaseMarketFunds(address(fundingToken), EcoVault.MarketAllocation.Buyback, 11);
    }

    function test_failedTokenTransferRestoresAllocationEffects() public {
        EcoVault vault = _prepare();
        vault.recordFee(address(fundingToken), 101, true);

        vm.expectRevert();
        vault.releaseMarketFunds(address(fundingToken), EcoVault.MarketAllocation.Buyback, 10);
        (, uint256 buyback, uint256 liquidity) = vault.allocations(address(fundingToken));
        assertEq(buyback, 10);
        assertEq(liquidity, 11);
    }

    function test_erc20OrderCompletionTransfersDueRemaindersToExecutor() public {
        EcoVault vault = _prepare();
        vault.recordFee(address(fundingToken), 101, true);
        fundingToken.mint(address(vault), 101);

        uint256 tokenBefore = fundingToken.balanceOf(address(this));
        uint256 firstOrderId = vault.scheduleBasketOrders(address(fundingToken));
        NarrativeOrderHub hub = registry.orderHub();
        assertEq(firstOrderId, 1);
        assertEq(hub.nextOrderId(), 3);
        assertEq(vault.scheduledBasket(address(fundingToken)), 80);
        (,,,,,, uint64 startAt,,,,) = hub.orders(firstOrderId);
        assertEq(startAt, block.timestamp);

        vm.warp(block.timestamp + 6 days);
        assertEq(hub.releaseDue(firstOrderId, 7), 40);
        vm.expectRevert(abi.encodeWithSelector(NarrativeOrderHub.InvalidStepLimit.selector, 9));
        hub.releaseDue(firstOrderId + 1, 9);
        assertEq(hub.releaseDue(firstOrderId + 1, 7), 40);
        assertEq(fundingToken.balanceOf(address(this)) - tokenBefore, 80);
        assertEq(vault.scheduledBasket(address(fundingToken)), 0);

        (
            ,,,,
            uint128 total,
            uint128 releasedTotal,,,
            uint8 totalSteps,
            uint8 releasedSteps,
            NarrativeOrderHub.Status status
        ) = hub.orders(firstOrderId);
        assertEq(total, 40);
        assertEq(releasedTotal, total);
        assertEq(totalSteps, 7);
        assertEq(releasedSteps, 7);
        assertEq(uint8(status), uint8(NarrativeOrderHub.Status.Complete));
    }

    function test_nativeOrderReleaseTransfersOnlyDueFunding() public {
        EcoVault vault = _prepare();
        vault.recordFee(address(0), 101, true);
        vm.deal(address(vault), 101);
        uint256 nativeBefore = address(this).balance;

        uint256 firstOrderId = vault.scheduleBasketOrders(address(0));
        vm.warp(block.timestamp + 6 days);
        assertEq(registry.orderHub().releaseDue(firstOrderId, 7), 40);
        assertEq(address(this).balance - nativeBefore, 40);
        assertEq(address(vault).balance, 61);
        assertEq(vault.scheduledBasket(address(0)), 40);
    }

    function test_onlyExecutorCanReleaseOrder() public {
        EcoVault vault = _prepare();
        vault.recordFee(address(fundingToken), 100, true);
        fundingToken.mint(address(vault), 100);
        uint256 orderId = vault.scheduleBasketOrders(address(fundingToken));
        NarrativeOrderHub hub = registry.orderHub();

        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(NarrativeOrderHub.OnlyExecutor.selector, address(0xBAD)));
        hub.releaseDue(orderId, 1);
        assertEq(vault.scheduledBasket(address(fundingToken)), 80);
    }

    function test_expiryRestoresOnlyUnreleasedBasketRemainder() public {
        EcoVault vault = _prepare();
        vault.recordFee(address(fundingToken), 100, true);
        fundingToken.mint(address(vault), 100);
        uint256 firstOrderId = vault.scheduleBasketOrders(address(fundingToken));
        uint256 released = registry.orderHub().releaseDue(firstOrderId, 1);
        assertEq(released, 5);
        vm.warp(block.timestamp + 7 days + 30 days + 1);

        assertEq(registry.orderHub().expire(firstOrderId), 35);
        assertEq(registry.orderHub().expire(firstOrderId + 1), 40);
        (uint256 restored,,) = vault.allocations(address(fundingToken));
        assertEq(restored, 75);
        assertEq(vault.scheduledBasket(address(fundingToken)), 0);
        assertEq(fundingToken.balanceOf(address(vault)), 95);
    }

    function _prepare() private returns (EcoVault vault) {
        (, address vaultAddress) = registry.preparePool(key, EcoPoolRegistry.Preset.Balanced, basket, 1 days, 7);
        vault = EcoVault(payable(vaultAddress));
    }

    function _fees(EcoPoolRegistry.Preset preset) private view returns (bytes32) {
        (uint16 buyFeeBps, uint16 sellFeeBps) = registry.feesForPreset(preset);
        return bytes32((uint256(buyFeeBps) << 16) | sellFeeBps);
    }
}
