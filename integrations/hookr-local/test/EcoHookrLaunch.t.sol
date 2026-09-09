// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookrLocalFixture} from "./HookrLocalFixture.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {HookrMarketCoordinatorV5} from "hookr/HookrMarketCoordinatorV5.sol";
import {HookrNativeMechanicsBlockV2} from "hookr/HookrNativeMechanicsBlockV2.sol";
import {HookrStackRegistryV1} from "hookr/HookrStackRegistryV1.sol";
import {HookrKernelRouterV3} from "hookr/HookrKernelRouterV3.sol";
import {HookrTokenV61} from "hookr/HookrTokenV61.sol";
import {HookrModuleTypesV1} from "hookr/libraries/HookrModuleTypesV1.sol";
import {EcoBasketModuleRegistry} from "eco/src/EcoBasketModuleRegistry.sol";
import {EcoHookrTestLauncher} from "../src/EcoHookrTestLauncher.sol";

contract EcoHookrLaunchTest is HookrLocalFixture {
    using PoolIdLibrary for PoolKey;

    function test_newTokenPredictionPreparationAndCreatorBuyAreAtomic() public {
        HookrMarketCoordinatorV5.NewTokenArgs memory args = _newArgs();
        args.initialBuy.quoteAmountIn = 0.01 ether;
        args.initialBuy.subjectAmountOutMinimum = 1;
        args.initialBuy.deadline = block.timestamp;
        bytes32 intent = keccak256("operator launch 1");
        address expected = coordinator.previewNewTokenAddress(args, intent);
        PoolKey memory key = coordinator.poolKeyFor(expected, args.market);
        assertEq(expected.code.length, 0);

        (address token, PoolId poolId) =
            launcher.openNew{value: 0.01 ether}(args, intent, _nativeConfig(), _settings(1), ecoModuleId);
        assertEq(token, expected);
        assertEq(PoolId.unwrap(poolId), PoolId.unwrap(key.toId()));
        assertEq(HookrTokenV61(token).creator(), address(launcher));
        assertEq(coordinator.getMarket(poolId).creator, address(launcher));
        assertEq(coordinator.getMarket(poolId).lpFeeRecipient, RECIPIENT);
        assertEq(coordinator.launchedByIntent(address(launcher), intent), token);
        assertTrue(stacks.stack(poolId).initialized);
        assertEq(stacks.stack(poolId).stackHash, coordinator.getMarket(poolId).stackHash);
        assertEq(
            stacks.frozenModuleConfigHash(poolId, address(ecoModule)), keccak256(eco.moduleConfig(poolId))
        );

        EcoPool memory pool = _ecoPool(key);
        assertEq(pool.buy.accountedClaims(), uint256(0.01 ether) * 75 / 10_000);
        assertGt(HookrTokenV61(token).balanceOf(address(this)), 0);
        assertEq(HookrTokenV61(token).balanceOf(address(launcher)), 0);
        assertEq(address(launcher).balance, 0);
        assertEq(address(coordinator).balance, 0);

        vm.expectRevert(
            abi.encodeWithSelector(
                HookrMarketCoordinatorV5.IntentAlreadyUsed.selector, address(launcher), intent, token
            )
        );
        launcher.openNew{value: 0.01 ether}(args, intent, _nativeConfig(), _settings(1), ecoModuleId);
    }

    function test_failedNewLaunchRollsBackPreparationAndTokenDeployment() public {
        HookrMarketCoordinatorV5.NewTokenArgs memory args = _newArgs();
        args.market.limits.maxSpecifiedQuoteTakeBps = 74;
        bytes32 intent = keccak256("retry launch");
        address predicted = coordinator.previewNewTokenAddress(args, intent);
        PoolKey memory key = coordinator.poolKeyFor(predicted, args.market);
        EcoHookrTestLauncher.EcoSettings memory settings = _settings(1);
        HookrNativeMechanicsBlockV2.Config memory cfg = _nativeConfig();

        vm.expectRevert(HookrStackRegistryV1.ModuleCapsExceedStackLimits.selector);
        launcher.openNew(args, intent, cfg, settings, ecoModuleId);
        assertEq(predicted.code.length, 0);
        assertFalse(eco.poolConfig(key.toId()).prepared);
        _assertNoStack(key.toId());
        assertEq(coordinator.marketCount(), 0);
        assertEq(coordinator.launchedByIntent(address(launcher), intent), address(0));

        args.market.limits.maxSpecifiedQuoteTakeBps = 75;
        (address token, PoolId poolId) = launcher.openNew(args, intent, cfg, settings, ecoModuleId);
        assertEq(token, predicted);
        assertTrue(stacks.stack(poolId).initialized);
    }

    function test_separatePreparationSurvivesFailedOpeningAndRetriesWithoutRedeployment() public {
        HookrMarketCoordinatorV5.ExistingTokenArgs memory args = _existingArgs();
        PoolKey memory key = coordinator.poolKeyFor(address(subject), args.market);
        EcoHookrTestLauncher.EcoSettings memory settings = _settings(1);
        bytes memory config = launcher.prepare(key, settings);
        EcoBasketModuleRegistry.PoolConfig memory prepared = eco.poolConfig(key.toId());
        args.market.limits.maxSpecifiedQuoteTakeBps = 74;
        HookrNativeMechanicsBlockV2.Config memory cfg = _nativeConfig();

        vm.expectRevert(HookrStackRegistryV1.ModuleCapsExceedStackLimits.selector);
        launcher.openExisting(args, cfg, settings, ecoModuleId);
        assertTrue(eco.poolConfig(key.toId()).prepared);
        _assertNoStack(key.toId());
        assertEq(address(prepared.vault).balance, 0);

        args.market.limits.maxSpecifiedQuoteTakeBps = 75;
        PoolId poolId = launcher.openExisting(args, cfg, settings, ecoModuleId);
        assertEq(eco.poolConfig(poolId).vault, prepared.vault);
        assertEq(eco.poolConfig(poolId).buyStrategy, prepared.buyStrategy);
        assertEq(eco.moduleConfig(poolId), config);
        assertTrue(stacks.stack(poolId).initialized);
    }

    function test_preparationRetryRejectsChangedEcoIntent() public {
        HookrMarketCoordinatorV5.ExistingTokenArgs memory args = _existingArgs();
        PoolKey memory key = coordinator.poolKeyFor(address(subject), args.market);
        launcher.prepare(key, _settings(1));
        EcoHookrTestLauncher.EcoSettings memory changed = _settings(2);
        HookrNativeMechanicsBlockV2.Config memory cfg = _nativeConfig();

        vm.expectRevert(EcoHookrTestLauncher.PreparedConfigMismatch.selector);
        launcher.openExisting(args, cfg, changed, ecoModuleId);
        _assertNoStack(key.toId());
    }

    function test_ecoOnlySelectionCannotBypassMandatoryNativeMechanics() public {
        HookrMarketCoordinatorV5.ExistingTokenArgs memory args = _existingArgs();
        PoolKey memory key = coordinator.poolKeyFor(address(subject), args.market);
        bytes memory config = launcher.prepare(key, _settings(1));
        args.market.modules = new HookrModuleTypesV1.ModuleSelection[](1);
        args.market.modules[0] = HookrModuleTypesV1.ModuleSelection(ecoModuleId, config);

        vm.expectRevert(HookrMarketCoordinatorV5.NativeMechanicsModuleRequired.selector);
        coordinator.openExistingTokenMarket(args);
        _assertNoStack(key.toId());
    }

    function test_launcherUsesItsCurrentCreatorTierWhenBuildingNativeConfig() public {
        HookrMarketCoordinatorV5.ExistingTokenArgs memory args = _existingArgs();
        HookrNativeMechanicsBlockV2.Config memory cfg = _nativeConfig();
        cfg.protocolShareBps = 2_000;
        coordinator.setCreatorTier(address(launcher), 1_000);
        PoolId poolId = launcher.openExisting(args, cfg, _settings(1), ecoModuleId);
        (, bytes memory frozen) = stacks.moduleAt(poolId, 0);
        HookrNativeMechanicsBlockV2.Config memory actual =
            abi.decode(frozen, (HookrNativeMechanicsBlockV2.Config));
        assertEq(actual.protocolShareBps, 1_000);
        assertEq(actual.protocolRecipient, address(treasury));
        assertEq(coordinator.getMarket(poolId).creator, address(launcher));
    }

    function test_exactOutputBuyIsBlockedDuringGuardAndSucceedsAfterExpiry() public {
        HookrMarketCoordinatorV5.NewTokenArgs memory args = _newArgs();
        HookrNativeMechanicsBlockV2.Config memory cfg = _nativeConfig();
        cfg.guardEndBlock = uint40(block.number + 10);
        cfg.lockedLiquidityProvider = address(coordinator);
        cfg.snipeTaxPips = 100_000;
        cfg.maxBuyQuoteAmount = 10 ether;
        (address token, PoolId poolId) = launcher.openNew(args, bytes32(0), cfg, _settings(1), ecoModuleId);
        EcoPool memory pool = _ecoPool(coordinator.poolKeyFor(token, args.market));
        HookrKernelRouterV3.ExactOutputParams memory params = _outputParams(pool.key, true, 0.1 ether);
        uint256 traderBefore = TRADER.balance;

        vm.expectPartialRevert(CustomRevert.WrappedError.selector);
        vm.prank(TRADER);
        router.exactOutput{value: 2 ether}(params, hex"");
        assertEq(TRADER.balance, traderBefore);
        assertEq(pool.buy.accountedClaims(), 0);
        assertEq(nativeBlock.totalClaimLiability(address(0)), 0);

        vm.roll(uint256(cfg.guardEndBlock) + 1);
        vm.prank(TRADER);
        uint256 spent = router.exactOutput{value: 2 ether}(params, hex"");
        assertEq(traderBefore - TRADER.balance, spent);
        assertEq(HookrTokenV61(token).balanceOf(RECIPIENT), 0.1 ether);
        assertGt(pool.buy.accountedClaims(), 0);
        assertEq(pool.buy.poolId(), PoolId.unwrap(poolId));
    }

    function test_noncanonicalBuyPriceLimitRevertsWithoutFeeStateChanges() public {
        EcoPool memory pool = _openExisting(1, _nativeConfig());
        HookrKernelRouterV3.ExactInputParams memory params = _inputParams(pool.key, true, 1 ether);
        params.sqrtPriceLimitX96 = PRICE_ONE - 1;
        uint256 traderBefore = TRADER.balance;

        vm.expectPartialRevert(CustomRevert.WrappedError.selector);
        vm.prank(TRADER);
        router.exactInput{value: 1 ether}(params, hex"");
        assertEq(TRADER.balance, traderBefore);
        assertEq(pool.buy.accountedClaims(), 0);
        assertEq(pool.buy.claimBalance(), 0);

        params.sqrtPriceLimitX96 = router.MIN_SQRT_PRICE_LIMIT();
        vm.prank(TRADER);
        router.exactInput{value: 1 ether}(params, hex"");
        assertEq(pool.buy.accountedClaims(), 0.0075 ether);
    }

    function _newArgs() internal view returns (HookrMarketCoordinatorV5.NewTokenArgs memory args) {
        args.name = "Eco local launch";
        args.symbol = "ELOCAL";
        args.expectedCreator = address(launcher);
        args.totalSupply = coordinator.SUPPLY();
        args.deploymentSalt = keccak256("local test token");
        args.market = _market();
        args.market.subjectAmount = uint128(args.totalSupply);
        args.market.lpFeeRecipient = RECIPIENT;
    }

    function _existingArgs() internal view returns (HookrMarketCoordinatorV5.ExistingTokenArgs memory) {
        return HookrMarketCoordinatorV5.ExistingTokenArgs(address(subject), _market());
    }
}

contract EcoHookrUnadmittedTest is HookrLocalFixture {
    using PoolIdLibrary for PoolKey;

    function _includeEcoInProfile() internal pure override returns (bool) {
        return false;
    }

    function test_catalogRegistrationCannotExpandAnExistingSealedProfile() public {
        HookrMarketCoordinatorV5.ExistingTokenArgs memory args =
            HookrMarketCoordinatorV5.ExistingTokenArgs(address(subject), _market());
        PoolKey memory key = coordinator.poolKeyFor(address(subject), args.market);
        HookrNativeMechanicsBlockV2.Config memory cfg = _nativeConfig();
        EcoHookrTestLauncher.EcoSettings memory settings = _settings(1);

        vm.expectRevert(
            abi.encodeWithSelector(
                HookrStackRegistryV1.ModuleOutsideRootProfile.selector, kernelId, ecoModuleId
            )
        );
        launcher.openExisting(args, cfg, settings, ecoModuleId);
        assertFalse(eco.poolConfig(key.toId()).prepared);
        _assertNoStack(key.toId());
        assertEq(coordinator.marketCount(), 0);
    }
}
