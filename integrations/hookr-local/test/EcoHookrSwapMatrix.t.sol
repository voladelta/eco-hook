// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookrLocalFixture} from "./HookrLocalFixture.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {HookrKernelRouterV3} from "hookr/HookrKernelRouterV3.sol";
import {HookrKernelQuoterV1} from "hookr/HookrKernelQuoterV1.sol";
import {HookrNativeMechanicsBlockV2} from "hookr/HookrNativeMechanicsBlockV2.sol";
import {HookrCorrectionPayloadV2} from "hookr/libraries/HookrCorrectionPayloadV2.sol";
import {EcoBasketClaimStrategyV1} from "eco/src/EcoBasketClaimStrategyV1.sol";

contract EcoHookrSwapMatrixTest is HookrLocalFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function test_growthAllFourQuadrants() public {
        _quadrants(0, hex"");
    }

    function test_balancedAllFourQuadrants() public {
        _quadrants(1, hex"");
    }

    function test_neutralAllFourQuadrants() public {
        _quadrants(2, hex"");
    }

    function test_nonemptyModuleDataPreservesQuoteAndSettlement() public {
        _quadrants(1, HookrCorrectionPayloadV2.encode(hex"1234", hex"", hex""));
    }

    function testFuzz_buyFeeRoundingAndSplitSettlement(uint128 amount) public {
        amount = uint128(bound(amount, 10_000, 1 ether));
        EcoPool memory pool = _openExisting(1, _nativeConfig());
        HookrKernelRouterV3.ExactInputParams memory params = _inputParams(pool.key, true, amount);
        vm.prank(TRADER);
        router.exactInput{value: amount}(params, hex"");

        uint256 fee = uint256(amount) * 75 / 10_000;
        assertEq(pool.buy.accountedClaims(), fee);
        uint256 first = fee / 3;
        vm.prank(RECIPIENT);
        pool.buy.settleClaims(first);
        vm.prank(RECIPIENT);
        pool.buy.settleClaims(fee - first);

        (uint256 basketAllocation, uint256 buyback, uint256 liquidity) = pool.vault.allocations(address(0));
        assertEq(basketAllocation, fee * 8 / 10);
        assertEq(buyback, (fee - basketAllocation) / 2);
        assertEq(basketAllocation + buyback + liquidity, fee);
        assertEq(address(pool.vault).balance, fee);
        assertEq(pool.buy.claimBalance(), 0);
        assertTrue(pool.buy.accountingInvariant());
    }

    function test_nativeAddonsAndEcoSettleSeparateBackedLiabilities() public {
        HookrNativeMechanicsBlockV2.Config memory cfg = _nativeConfig();
        cfg.maxFeePips = 10_000;
        cfg.surgeSens = 2;
        cfg.burnBps = 200;
        cfg.lpBps = 50;
        cfg.potBps = 50;
        cfg.potEveryNBuys = 2;
        cfg.potMinBuyWei = 0.001 ether;
        cfg.royaltyBps = 500;
        cfg.royaltyTo = address(0xC0FFEE);
        EcoPool memory pool = _openExisting(1, cfg);
        assertEq(coordinator.protocolShareBps(address(launcher)), 2_000);

        _assertNativeBuyRecipients(pool, cfg.royaltyTo);
        this.quoteAndSwap(pool, false, true, 0.5 ether, hex"");
        this.quoteAndSwap(pool, true, false, 0.5 ether, hex"");
        this.quoteAndSwap(pool, false, false, 0.5 ether, hex"");

        _settleNativeAndEcoRecipients(pool, cfg.royaltyTo);
    }

    function _assertNativeBuyRecipients(EcoPool memory pool, address royaltyTo) internal {
        bytes32 poolId = PoolId.unwrap(pool.key.toId());
        uint256 expectedTreasury = _oneEtherBuyProtocolFee(pool.key);
        this.quoteAndSwap(pool, true, true, 1 ether, hex"");
        assertEq(nativeBlock.potBuyCount(PoolId.unwrap(pool.key.toId())), 1);
        // The 0.01 ETH LP/pot cut splits 38% each to LP and pot, 4% to royalty, 20% to treasury.
        assertEq(nativeBlock.totalLpDonatedWei(poolId), 0.0038 ether);
        assertEq(nativeBlock.potWei(poolId), 0.0038 ether);
        assertEq(nativeBlock.claimable(address(0), royaltyTo), 0.0004 ether);
        assertEq(nativeBlock.claimable(address(0), RECIPIENT), 0);
        assertEq(pool.buy.accountedClaims(), 0.0075 ether);
        assertEq(nativeBlock.claimable(address(0), address(treasury)), expectedTreasury);

        // Native Mechanics counts at most one qualifying pot buy per block.
        vm.roll(block.number + 1);
        expectedTreasury += _oneEtherBuyProtocolFee(pool.key);
        this.quoteAndSwap(pool, true, true, 1 ether, hex"");
        assertEq(nativeBlock.totalLpDonatedWei(poolId), 0.0076 ether);
        assertEq(nativeBlock.potWei(poolId), 0);
        assertEq(nativeBlock.totalPotPaidWei(poolId), 0.0076 ether);
        assertEq(nativeBlock.claimable(address(0), RECIPIENT), 0.0076 ether);
        assertEq(nativeBlock.claimable(address(0), royaltyTo), 0.0008 ether);
        assertEq(pool.buy.accountedClaims(), 0.015 ether);
        assertEq(nativeBlock.claimable(address(0), address(treasury)), expectedTreasury);
    }

    function _settleNativeAndEcoRecipients(EcoPool memory pool, address royaltyTo) internal {
        bytes32 poolId = PoolId.unwrap(pool.key.toId());
        assertGt(nativeBlock.totalBurnedTokens(poolId), 0);
        assertGt(nativeBlock.totalLpDonatedWei(poolId), 0);
        assertGt(nativeBlock.totalPotPaidWei(poolId), 0);
        assertGt(nativeBlock.totalProtocolShareWei(poolId), 0);
        assertEq(manager.balanceOf(address(nativeBlock), 0), nativeBlock.totalClaimLiability(address(0)));
        uint256 ecoClaims = pool.buy.accountedClaims() + pool.sell.accountedClaims();
        assertGt(ecoClaims, 0);

        uint256 payout = nativeBlock.claimable(address(0), address(treasury));
        assertEq(payout, nativeBlock.totalProtocolShareWei(poolId));
        assertEq(nativeBlock.claimable(address(0), RECIPIENT), 0.0076 ether);
        assertEq(nativeBlock.claimable(address(0), royaltyTo), 0.0008 ether);
        assertEq(nativeBlock.totalClaimLiability(address(0)), payout + 0.0084 ether);
        uint256 beforeTreasury = TREASURY.balance;
        vm.prank(RECIPIENT);
        assertEq(treasury.collect(address(0)), payout);
        assertEq(TREASURY.balance - beforeTreasury, payout);
        assertEq(nativeBlock.claimable(address(0), address(treasury)), 0);
        assertEq(nativeBlock.claimable(address(0), RECIPIENT), 0.0076 ether);
        assertEq(nativeBlock.claimable(address(0), royaltyTo), 0.0008 ether);
        assertEq(pool.buy.accountedClaims() + pool.sell.accountedClaims(), ecoClaims);
        assertEq(manager.balanceOf(address(nativeBlock), 0), nativeBlock.totalClaimLiability(address(0)));

        uint256 beforeRecipient = RECIPIENT.balance;
        vm.prank(RECIPIENT);
        nativeBlock.claim(address(0));
        assertEq(RECIPIENT.balance - beforeRecipient, 0.0076 ether);

        uint256 beforeRoyalty = royaltyTo.balance;
        vm.prank(royaltyTo);
        nativeBlock.claim(address(0));
        assertEq(royaltyTo.balance - beforeRoyalty, 0.0008 ether);
        assertEq(nativeBlock.totalClaimLiability(address(0)), 0);
        assertEq(manager.balanceOf(address(nativeBlock), 0), 0);

        pool.buy.settleClaims(pool.buy.accountedClaims());
        pool.sell.settleClaims(pool.sell.accountedClaims());
        assertEq(address(pool.vault).balance, ecoClaims);
        assertTrue(pool.buy.accountingInvariant());
        assertTrue(pool.sell.accountingInvariant());
    }

    function _oneEtherBuyProtocolFee(PoolKey memory key) internal view returns (uint256) {
        PoolId poolId = key.toId();
        (uint160 price,,,) = IPoolManager(address(manager)).getSlot0(poolId);
        uint256 quoteReserve = (uint256(IPoolManager(address(manager)).getLiquidity(poolId)) << 96) / price;
        uint256 pressure = 1 ether * 2 * 1_000_000 / quoteReserve;
        if (pressure > 1_000_000) pressure = 1_000_000;
        uint256 surgePips = 7_000 * pressure / 1_000_000;
        // Treasury receives 20% of surge, 40 bps for burn, and 20% of the 1% LP/pot cut.
        return 1 ether * (surgePips * 2_000 / 10_000 + 4_000) / 1_000_000 + 0.002 ether;
    }

    function _quadrants(uint8 preset, bytes memory data) internal {
        EcoPool memory pool = _openExisting(preset, _nativeConfig());
        uint16[3] memory buyRates = [uint16(100), 75, 50];
        uint16[3] memory sellRates = [uint16(0), 25, 50];
        for (uint256 quadrant; quadrant < 4; ++quadrant) {
            bool buy = quadrant < 2;
            bool exactInput = quadrant % 2 == 0;
            EcoBasketClaimStrategyV1 strategy = buy ? pool.buy : pool.sell;
            uint256 prior = address(strategy) == address(0) ? 0 : strategy.accountedClaims();
            (uint256 amountIn, uint256 amountOut) = this.quoteAndSwap(pool, buy, exactInput, 0.5 ether, data);
            uint256 fee = address(strategy) == address(0) ? 0 : strategy.accountedClaims() - prior;
            uint256 rate = buy ? buyRates[preset] : sellRates[preset];

            if (exactInput) {
                uint256 quoteAmount = buy ? amountIn : amountOut + fee;
                assertEq(fee, quoteAmount * rate / 10_000);
            } else {
                uint256 netQuote = buy ? amountIn - fee : amountOut;
                uint256 denominator = 10_000 - rate;
                assertEq(fee, (netQuote * rate + denominator - 1) / denominator);
            }
        }

        assertEq(nativeBlock.totalClaimLiability(address(0)), 0, "base LP fee is not protocol revenue");
        uint256 total = pool.buy.accountedClaims();
        pool.buy.settleClaims(total);
        if (address(pool.sell) != address(0)) {
            uint256 sellClaims = pool.sell.accountedClaims();
            total += sellClaims;
            pool.sell.settleClaims(sellClaims);
        }
        assertEq(address(pool.vault).balance, total);
        (uint256 basketAllocation, uint256 buyback, uint256 liquidity) = pool.vault.allocations(address(0));
        assertEq(basketAllocation + buyback + liquidity, total);
    }

    // An external test boundary prevents Solc 0.8.26 from inlining the swap matrix past its stack limit.
    function quoteAndSwap(EcoPool memory pool, bool buy, bool exactInput, uint128 amount, bytes memory data)
        external
        returns (uint256 amountIn, uint256 amountOut)
    {
        HookrKernelQuoterV1.QuoteParams memory quote = HookrKernelQuoterV1.QuoteParams({
            key: pool.key,
            payer: TRADER,
            recipient: RECIPIENT,
            zeroForOne: buy,
            amountSpecified: exactInput ? -int128(amount) : int128(amount),
            amountBound: exactInput ? 1 : uint128(2 ether),
            sqrtPriceLimitX96: buy ? router.MIN_SQRT_PRICE_LIMIT() : router.MAX_SQRT_PRICE_LIMIT()
        });
        bytes32 stateBefore = _stateFingerprint(pool);
        (uint256 quotedIn, uint256 quotedOut) = quoter.quote(quote, data);
        assertEq(_stateFingerprint(pool), stateBefore, "quoter must roll back claims and pool state");

        uint256 payerBefore = buy ? TRADER.balance : subject.balanceOf(TRADER);
        uint256 recipientBefore = buy ? subject.balanceOf(RECIPIENT) : RECIPIENT.balance;
        if (exactInput) {
            HookrKernelRouterV3.ExactInputParams memory params = _inputParams(pool.key, buy, amount);
            params.amountOutMinimum = uint128(quotedOut);
            vm.prank(TRADER);
            amountOut = router.exactInput{value: buy ? amount : 0}(params, data);
            amountIn = amount;
        } else {
            HookrKernelRouterV3.ExactOutputParams memory params = _outputParams(pool.key, buy, amount);
            vm.prank(TRADER);
            amountIn = router.exactOutput{value: buy ? params.amountInMaximum : 0}(params, data);
            amountOut = amount;
        }

        assertEq(amountIn, quotedIn);
        assertEq(amountOut, quotedOut);
        assertEq(payerBefore - (buy ? TRADER.balance : subject.balanceOf(TRADER)), amountIn);
        assertEq((buy ? subject.balanceOf(RECIPIENT) : RECIPIENT.balance) - recipientBefore, amountOut);
        assertEq(pool.buy.accountedClaims(), manager.balanceOf(address(pool.buy), 0));
        if (address(pool.sell) != address(0)) {
            assertEq(pool.sell.accountedClaims(), manager.balanceOf(address(pool.sell), 0));
        }
        assertEq(address(router).balance, 0, "unused native prefund must be refunded");
        assertEq(subject.balanceOf(address(router)), 0);
    }

    function _stateFingerprint(EcoPool memory pool) internal view returns (bytes32) {
        PoolId poolId = pool.key.toId();
        (uint160 price, int24 tick, uint24 protocolFee, uint24 lpFee) =
            IPoolManager(address(manager)).getSlot0(poolId);
        bytes32 nativeState = keccak256(
            abi.encode(
                price,
                tick,
                protocolFee,
                lpFee,
                manager.balanceOf(address(nativeBlock), 0),
                nativeBlock.totalClaimLiability(address(0)),
                nativeBlock.totalHookFeesWei(PoolId.unwrap(poolId)),
                nativeBlock.totalBurnedTokens(PoolId.unwrap(poolId)),
                nativeBlock.potBuyCount(PoolId.unwrap(poolId)),
                nativeBlock.potWei(PoolId.unwrap(poolId))
            )
        );
        return keccak256(
            abi.encode(
                nativeState,
                manager.balanceOf(address(pool.buy), 0),
                manager.balanceOf(address(pool.sell), 0),
                pool.buy.accountedClaims(),
                address(pool.sell) == address(0) ? 0 : pool.sell.accountedClaims(),
                address(manager).balance,
                subject.balanceOf(address(manager)),
                subject.balanceOf(RECIPIENT),
                RECIPIENT.balance
            )
        );
    }
}
