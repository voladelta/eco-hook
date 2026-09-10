// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookrLocalFixture} from "./HookrLocalFixture.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrKernelQuoterV1} from "hookr/HookrKernelQuoterV1.sol";
import {HookrKernelRouterV3} from "hookr/HookrKernelRouterV3.sol";
import {HookrNativeMechanicsBlockV2} from "hookr/HookrNativeMechanicsBlockV2.sol";

interface IUniversalRouterLocal {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
    function poolManager() external view returns (address);
}

interface IPermit2Local {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

contract EcoHookrForkTest is HookrLocalFixture {
    using stdJson for string;
    using PoolIdLibrary for PoolKey;

    // ABI and action IDs checked against this runtime's verified Sourcify sources.
    // Both single-swap tuples include minHopPriceX36 before hookData in this release.
    struct SingleSwap {
        PoolKey key;
        bool zeroForOne;
        uint128 amount;
        uint128 bound;
        uint256 minHopPriceX36;
        bytes hookData;
    }

    IUniversalRouterLocal internal universal;
    IPermit2Local internal permit2;

    function setUp() public override {
        if (bytes(vm.envOr("HOOKR_FORK_RPC_URL", string(""))).length == 0) {
            vm.skip(true);
        }
        super.setUp();
        assertEq(universal.poolManager(), address(manager));
        assertEq(address(universal).balance, 0, "fork fixture requires an empty router balance");
        vm.startPrank(TRADER);
        subject.approve(address(permit2), type(uint256).max);
        permit2.approve(
            address(subject), address(universal), type(uint160).max, uint48(block.timestamp + 1 days)
        );
        vm.stopPrank();
    }

    function _createManager() internal override returns (PoolManager) {
        string memory pin = vm.readFile(string.concat(vm.projectRoot(), "/fork-source.json"));
        uint256 pinnedBlock = pin.readUint(".blockNumber");
        vm.createSelectFork(vm.envString("HOOKR_FORK_RPC_URL"), pinnedBlock);
        assertEq(vm.getChainId(), pin.readUint(".chainId"));
        assertEq(block.number, pin.readUint(".blockNumber"));
        assertEq(keccak256(vm.getRawBlockHeader(pinnedBlock)), pin.readBytes32(".blockHash"));
        assertEq(blockhash(block.number - 1), pin.readBytes32(".parentBlockHash"));
        address deployedManager = pin.readAddress(".poolManager");
        address deployedRouter = pin.readAddress(".universalRouter");
        address deployedPermit2 = pin.readAddress(".permit2");
        assertEq(deployedManager.codehash, pin.readBytes32(".poolManagerCodeHash"));
        assertEq(deployedRouter.codehash, pin.readBytes32(".universalRouterCodeHash"));
        assertEq(deployedPermit2.codehash, pin.readBytes32(".permit2CodeHash"));
        universal = IUniversalRouterLocal(deployedRouter);
        permit2 = IPermit2Local(deployedPermit2);
        return PoolManager(deployedManager);
    }

    function test_forkUniversalRouterAllFourQuadrantsAndClaimSettlement() public {
        EcoPool memory pool = _openExisting(1, _nativeConfig());
        for (uint256 quadrant; quadrant < 4; ++quadrant) {
            bool buy = quadrant < 2;
            bool exactInput = quadrant % 2 == 0;
            HookrKernelQuoterV1.QuoteParams memory params = HookrKernelQuoterV1.QuoteParams({
                key: pool.key,
                payer: TRADER,
                recipient: RECIPIENT,
                zeroForOne: buy,
                amountSpecified: exactInput ? -int128(0.5 ether) : int128(0.5 ether),
                amountBound: exactInput ? 1 : uint128(2 ether),
                sqrtPriceLimitX96: buy ? router.MIN_SQRT_PRICE_LIMIT() : router.MAX_SQRT_PRICE_LIMIT()
            });
            // With native add-ons disabled, trusted/untrusted routing has the same fee model.
            (uint256 quotedIn, uint256 quotedOut) = quoter.quote(params, hex"");
            uint256 payerBefore = buy ? TRADER.balance : subject.balanceOf(TRADER);
            uint256 recipientBefore = buy ? subject.balanceOf(RECIPIENT) : RECIPIENT.balance;
            _universalSwap(pool.key, buy, exactInput, uint128(quotedOut), hex"");

            assertEq(payerBefore - (buy ? TRADER.balance : subject.balanceOf(TRADER)), quotedIn);
            assertEq((buy ? subject.balanceOf(RECIPIENT) : RECIPIENT.balance) - recipientBefore, quotedOut);
            assertEq(address(universal).balance, 0, "SWEEP must refund unused native input");
            assertEq(subject.balanceOf(address(universal)), 0);
            assertEq(manager.balanceOf(address(pool.buy), 0), pool.buy.accountedClaims());
            assertEq(manager.balanceOf(address(pool.sell), 0), pool.sell.accountedClaims());
        }

        uint256 buyClaims = pool.buy.accountedClaims();
        uint256 sellClaims = pool.sell.accountedClaims();
        uint256 fees = buyClaims + sellClaims;
        vm.prank(RECIPIENT);
        pool.buy.settleClaims(buyClaims);
        vm.prank(RECIPIENT);
        pool.sell.settleClaims(sellClaims);
        assertEq(address(pool.vault).balance, fees);
        assertEq(pool.buy.claimBalance(), 0);
        assertEq(pool.sell.claimBalance(), 0);
    }

    function test_forkPotParticipationDiffersButEcoFeeDoesNot() public {
        HookrNativeMechanicsBlockV2.Config memory cfg = _nativeConfig();
        cfg.potBps = 50;
        cfg.potEveryNBuys = 2;
        cfg.potMinBuyWei = 0.001 ether;
        EcoPool memory pool = _openExisting(1, cfg);
        uint256 snapshot = vm.snapshotState();
        HookrKernelRouterV3.ExactInputParams memory params = _inputParams(pool.key, true, 0.5 ether);
        vm.prank(TRADER);
        uint256 hookrOutput = router.exactInput{value: 0.5 ether}(params, hex"");
        uint256 hookrEcoFee = pool.buy.accountedClaims();
        assertEq(nativeBlock.potBuyCount(PoolId.unwrap(pool.key.toId())), 1);
        assertGt(nativeBlock.potWei(PoolId.unwrap(pool.key.toId())), 0);

        assertTrue(vm.revertToState(snapshot));
        uint256 recipientBefore = subject.balanceOf(RECIPIENT);
        _universalSwap(pool.key, true, true, 1, hex"");
        assertGt(subject.balanceOf(RECIPIENT) - recipientBefore, hookrOutput);
        assertEq(pool.buy.accountedClaims(), hookrEcoFee);
        assertEq(nativeBlock.potBuyCount(PoolId.unwrap(pool.key.toId())), 0);
        assertEq(nativeBlock.potWei(PoolId.unwrap(pool.key.toId())), 0);
        assertEq(nativeBlock.totalClaimLiability(address(0)), 0);
    }

    function test_forkUniversalRouterRejectsNonemptyHookDataAtomically() public {
        EcoPool memory pool = _openExisting(1, _nativeConfig());
        uint256 payerBefore = TRADER.balance;
        (bytes memory commands, bytes[] memory inputs) = _universalPlan(pool.key, true, true, 1, hex"abcd");
        vm.expectRevert();
        vm.prank(TRADER);
        universal.execute{value: 0.5 ether}(commands, inputs, block.timestamp);
        assertEq(TRADER.balance, payerBefore);
        assertEq(pool.buy.accountedClaims(), 0);
        assertEq(pool.buy.claimBalance(), 0);

        _universalSwap(pool.key, true, true, 1, hex"");
        assertEq(pool.buy.accountedClaims(), 0.00375 ether);
    }

    function _universalSwap(
        PoolKey memory key,
        bool buy,
        bool exactInput,
        uint128 minOut,
        bytes memory hookData
    ) internal {
        (bytes memory commands, bytes[] memory inputs) =
            _universalPlan(key, buy, exactInput, minOut, hookData);
        uint256 value = buy ? (exactInput ? 0.5 ether : 2 ether) : 0;
        vm.prank(TRADER);
        universal.execute{value: value}(commands, inputs, block.timestamp);
    }

    function _universalPlan(
        PoolKey memory key,
        bool buy,
        bool exactInput,
        uint128 minOut,
        bytes memory hookData
    ) internal pure returns (bytes memory commands, bytes[] memory inputs) {
        bytes[] memory actions = new bytes[](3);
        actions[0] =
            abi.encode(SingleSwap(key, buy, 0.5 ether, exactInput ? minOut : uint128(2 ether), 0, hookData));
        Currency currencyIn = buy ? key.currency0 : key.currency1;
        Currency currencyOut = buy ? key.currency1 : key.currency0;
        actions[1] = abi.encode(currencyIn, exactInput ? uint256(0.5 ether) : uint256(2 ether));
        // TAKE with OPEN_DELTA=0 delivers the full credit to a third-party recipient.
        actions[2] = abi.encode(currencyOut, RECIPIENT, uint256(0));
        inputs = new bytes[](2);
        inputs[0] = abi.encode(exactInput ? hex"060c0e" : hex"080c0e", actions);
        inputs[1] = abi.encode(address(0), TRADER, uint256(0));
        // V4_SWAP followed by native SWEEP refunds exact-output overfunding.
        commands = hex"1004";
    }
}
