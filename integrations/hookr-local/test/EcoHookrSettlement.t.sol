// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookrLocalFixture} from "./HookrLocalFixture.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookrKernelRouterV3} from "hookr/HookrKernelRouterV3.sol";

contract EcoHookrSettlementTest is HookrLocalFixture {
    using PoolIdLibrary for PoolKey;

    function test_balancedBuySellAndPermissionlessSettlement() public {
        EcoPool memory pool = _openExisting(1, _nativeConfig());
        assertTrue(stacks.stack(pool.key.toId()).initialized);
        assertEq(stacks.stack(pool.key.toId()).kernel, address(hook));
        assertEq(stacks.stack(pool.key.toId()).moduleCount, 2);

        HookrKernelRouterV3.ExactInputParams memory buy = _inputParams(pool.key, true, 1 ether);
        uint256 nativeBefore = TRADER.balance;
        uint256 recipientBefore = subject.balanceOf(RECIPIENT);
        vm.prank(TRADER);
        uint256 bought = router.exactInput{value: 1 ether}(buy, hex"");
        assertEq(nativeBefore - TRADER.balance, 1 ether);
        assertEq(subject.balanceOf(RECIPIENT) - recipientBefore, bought);
        uint256 buyFee = 0.0075 ether;
        assertEq(pool.buy.accountedClaims(), buyFee);
        assertEq(manager.balanceOf(address(pool.buy), 0), buyFee);
        assertEq(pool.sell.accountedClaims(), 0);

        HookrKernelRouterV3.ExactInputParams memory sell = _inputParams(pool.key, false, 0.5 ether);
        uint256 subjectBefore = subject.balanceOf(TRADER);
        uint256 recipientNativeBefore = RECIPIENT.balance;
        vm.prank(TRADER);
        uint256 sold = router.exactInput(sell, hex"");
        assertEq(subjectBefore - subject.balanceOf(TRADER), 0.5 ether);
        assertEq(RECIPIENT.balance - recipientNativeBefore, sold);
        uint256 sellFee = pool.sell.accountedClaims();
        assertEq(sellFee, (sold + sellFee) * 25 / 10_000);
        assertGt(sellFee, 0);
        assertEq(manager.balanceOf(address(pool.sell), 0), sellFee);

        uint256 settlerBefore = RECIPIENT.balance;
        vm.prank(RECIPIENT);
        pool.buy.settleClaims(buyFee);
        vm.prank(RECIPIENT);
        pool.sell.settleClaims(sellFee);
        assertEq(RECIPIENT.balance, settlerBefore);
        assertEq(address(pool.vault).balance, buyFee + sellFee);
        assertEq(manager.balanceOf(address(pool.buy), 0), 0);
        assertEq(manager.balanceOf(address(pool.sell), 0), 0);
        assertTrue(pool.buy.accountingInvariant());
        assertTrue(pool.sell.accountingInvariant());

        (uint256 basket, uint256 buyback, uint256 liquidity) = pool.vault.allocations(address(0));
        assertEq(basket, buyFee * 80 / 100);
        assertEq(buyback, buyFee / 10 + sellFee / 2);
        assertEq(basket + buyback + liquidity, buyFee + sellFee);
        assertEq(address(router).balance, 0);
        assertEq(subject.balanceOf(address(router)), 0);
        assertEq(address(hook).balance, 0);
    }
}
