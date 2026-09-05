// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {EcoBasketClaimStrategyV1} from "../../src/EcoBasketClaimStrategyV1.sol";
import {EcoBasketModuleRegistry} from "../../src/EcoBasketModuleRegistry.sol";
import {EcoBasketModuleV1} from "../../src/EcoBasketModuleV1.sol";
import {EcoBasketModuleVault} from "../../src/EcoBasketModuleVault.sol";
import {NarrativeOrderHub} from "../../src/NarrativeOrderHub.sol";
import {HookrModuleTypesV1} from "../../src/hookr-v6/HookrModuleTypesV1.sol";

contract ModuleClaimsPoolManagerMock {
    mapping(address account => mapping(uint256 currencyId => uint256 amount)) private _claims;

    receive() external payable {}

    function mintClaim(address account, uint256 currencyId, uint256 amount) external {
        _claims[account][currencyId] += amount;
    }

    function balanceOf(address account, uint256 currencyId) external view returns (uint256) {
        return _claims[account][currencyId];
    }

    function unlock(bytes calldata data) external returns (bytes memory) {
        return IUnlockCallback(msg.sender).unlockCallback(data);
    }

    function burn(address from, uint256 currencyId, uint256 amount) external {
        uint256 available = _claims[from][currencyId];
        require(amount <= available, "insufficient claims");
        _claims[from][currencyId] = available - amount;
    }

    function take(Currency currency, address to, uint256 amount) external {
        require(Currency.unwrap(currency) == address(0), "native only");
        (bool sent,) = payable(to).call{value: amount}("");
        require(sent, "native transfer failed");
    }
}

contract ModuleKernelMock {
    ModuleClaimsPoolManagerMock public immutable manager;

    constructor(ModuleClaimsPoolManagerMock manager_) {
        manager = manager_;
    }

    function poolManager() external view returns (IPoolManager) {
        return IPoolManager(address(manager));
    }

    function credit(EcoBasketClaimStrategyV1 strategy, uint256 amount) external {
        manager.mintClaim(address(strategy), 0, amount);
        strategy.creditClaims(amount);
    }

    function creditWithoutBacking(EcoBasketClaimStrategyV1 strategy, uint256 amount) external {
        strategy.creditClaims(amount);
    }
}

contract EcoBasketModuleTest is Test {
    using PoolIdLibrary for PoolKey;

    address internal constant EXECUTOR = address(0xE0);
    address internal constant SUBJECT = address(0x1000);
    address internal constant BASKET_TOKEN = address(0x2000);

    ModuleClaimsPoolManagerMock internal manager;
    ModuleKernelMock internal kernel;
    EcoBasketModuleRegistry internal registry;
    EcoBasketModuleV1 internal module;
    PoolKey internal key;
    PoolId internal poolId;
    bytes internal config;
    EcoBasketModuleVault internal vault;
    EcoBasketClaimStrategyV1 internal buyStrategy;
    EcoBasketClaimStrategyV1 internal sellStrategy;

    function setUp() public {
        manager = new ModuleClaimsPoolManagerMock();
        kernel = new ModuleKernelMock(manager);
        registry = new EcoBasketModuleRegistry(address(this), EXECUTOR);
        module = registry.module();
        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(SUBJECT),
            fee: registry.DYNAMIC_FEE_FLAG(),
            tickSpacing: 60,
            hooks: IHooks(address(kernel))
        });
        address[] memory basket = new address[](1);
        basket[0] = BASKET_TOKEN;
        (poolId, config) = registry.preparePool(key, module.BALANCED_PRESET(), basket, 1 days, 10);
        EcoBasketModuleRegistry.PoolConfig memory prepared = registry.poolConfig(poolId);
        vault = EcoBasketModuleVault(payable(prepared.vault));
        buyStrategy = EcoBasketClaimStrategyV1(prepared.buyStrategy);
        sellStrategy = EcoBasketClaimStrategyV1(prepared.sellStrategy);
    }

    function test_preparesCanonicalConfigAndValidatesExactStackBindings() public view {
        assertEq(PoolId.unwrap(poolId), PoolId.unwrap(key.toId()));
        assertEq(registry.moduleConfig(poolId), config);
        assertTrue(registry.isVault(address(vault)));
        assertTrue(registry.isStrategy(address(buyStrategy)));
        assertTrue(registry.isStrategy(address(sellStrategy)));
        assertEq(vault.buyStrategy(), address(buyStrategy));
        assertEq(vault.sellStrategy(), address(sellStrategy));
        assertEq(address(buyStrategy.poolManager()), address(manager));
        assertEq(buyStrategy.kernel(), address(kernel));
        assertEq(buyStrategy.poolId(), PoolId.unwrap(poolId));
        assertTrue(buyStrategy.isBuy());
        assertFalse(sellStrategy.isBuy());

        assertEq(module.validateConfig(config), keccak256(config));
        HookrModuleTypesV1.ModuleConfigCaps memory caps =
            module.validateStack(PoolId.unwrap(poolId), address(kernel), SUBJECT, address(0), config);
        assertEq(caps.configHash, keccak256(config));
        assertEq(caps.maxSpecifiedQuoteTakeBps, 75);
        assertEq(caps.maxUnspecifiedQuoteTakeBps, 75);
        assertEq(caps.maxSubjectTakeBps, 0);
    }

    function test_routesAllFourSwapQuadrantsToDirectionBoundStrategies() public view {
        HookrModuleTypesV1.ModuleResult memory exactInputBuy = module.beforeSwap(_swap(true, true), config);
        _assertResult(exactInputBuy, 75, address(buyStrategy), module.BUY_ATTRIBUTION_KEY());

        HookrModuleTypesV1.ModuleResult memory exactOutputSell = module.beforeSwap(_swap(false, false), config);
        _assertResult(exactOutputSell, 25, address(sellStrategy), module.SELL_ATTRIBUTION_KEY());

        HookrModuleTypesV1.ModuleResult memory exactOutputBuy = module.afterSwap(_afterSwap(true, false), config);
        _assertResult(exactOutputBuy, 75, address(buyStrategy), module.BUY_ATTRIBUTION_KEY());

        HookrModuleTypesV1.ModuleResult memory exactInputSell = module.afterSwap(_afterSwap(false, true), config);
        _assertResult(exactInputSell, 25, address(sellStrategy), module.SELL_ATTRIBUTION_KEY());

        assertEq(module.beforeSwap(_swap(false, true), config).quoteTakeBps, 0);
        assertEq(module.afterSwap(_afterSwap(true, true), config).quoteTakeBps, 0);
    }

    function test_settlesBackedQuoteClaimsIntoDirectionSpecificVaultAllocations() public {
        vm.deal(address(manager), 140 ether);
        kernel.credit(buyStrategy, 100 ether);
        kernel.credit(sellStrategy, 40 ether);

        buyStrategy.settleClaims(100 ether);
        sellStrategy.settleClaims(40 ether);

        assertEq(address(vault).balance, 140 ether);
        assertEq(buyStrategy.accountedClaims(), 0);
        assertEq(sellStrategy.accountedClaims(), 0);
        assertEq(buyStrategy.claimBalance(), 0);
        assertEq(sellStrategy.claimBalance(), 0);
        assertTrue(buyStrategy.accountingInvariant());
        assertTrue(sellStrategy.accountingInvariant());

        (uint256 basket, uint256 buyback, uint256 liquidity) = vault.allocations(address(0));
        assertEq(basket, 80 ether);
        assertEq(buyback, 30 ether);
        assertEq(liquidity, 30 ether);
    }

    function test_rejectsUnbackedClaimsAndUnauthorizedVaultAccounting() public {
        vm.expectRevert(abi.encodeWithSelector(EcoBasketClaimStrategyV1.ClaimBalanceMismatch.selector, 1 ether, 0));
        kernel.creditWithoutBacking(buyStrategy, 1 ether);

        vm.expectRevert(abi.encodeWithSelector(EcoBasketClaimStrategyV1.NotKernel.selector, address(this)));
        buyStrategy.creditClaims(1 ether);

        vm.expectRevert(abi.encodeWithSelector(EcoBasketModuleVault.InvalidSource.selector, address(this), true));
        vault.recordFee(address(0), 1 ether, true);
    }

    function test_onlyApprovedAdapterCanPreparePool() public {
        EcoBasketModuleRegistry restrictedRegistry = new EcoBasketModuleRegistry(address(0xA11CE), EXECUTOR);
        address[] memory basket = new address[](1);
        basket[0] = BASKET_TOKEN;
        uint8 preset = restrictedRegistry.module().BALANCED_PRESET();

        vm.expectRevert(abi.encodeWithSelector(EcoBasketModuleRegistry.OnlyApprovedAdapter.selector, address(this)));
        restrictedRegistry.preparePool(key, preset, basket, 1 days, 10);
    }

    function test_rejectsDuplicatePoolPreparation() public {
        address[] memory basket = new address[](1);
        basket[0] = BASKET_TOKEN;
        uint8 preset = module.BALANCED_PRESET();

        vm.expectRevert(abi.encodeWithSelector(EcoBasketModuleRegistry.PoolAlreadyPrepared.selector, poolId));
        registry.preparePool(key, preset, basket, 1 days, 10);
    }

    function test_rejectsUnknownPreset() public {
        PoolKey memory unknownPresetKey = key;
        unknownPresetKey.currency1 = Currency.wrap(address(0x3000));
        address[] memory basket = new address[](1);
        basket[0] = BASKET_TOKEN;
        uint8 preset = module.NEUTRAL_PRESET() + 1;

        vm.expectRevert(EcoBasketModuleRegistry.InvalidPool.selector);
        registry.preparePool(unknownPresetKey, preset, basket, 1 days, 10);
    }

    function test_growthPresetHasNoSellStrategyOrSellFee() public {
        PoolKey memory growthKey = key;
        growthKey.currency1 = Currency.wrap(address(0x3000));
        address[] memory basket = new address[](1);
        basket[0] = BASKET_TOKEN;
        (PoolId growthPoolId, bytes memory growthConfig) =
            registry.preparePool(growthKey, module.GROWTH_PRESET(), basket, 1 days, 10);
        EcoBasketModuleRegistry.PoolConfig memory prepared = registry.poolConfig(growthPoolId);

        assertEq(prepared.sellStrategy, address(0));
        assertEq(module.beforeSwap(_swap(false, false), growthConfig).quoteTakeBps, 0);
        assertEq(module.afterSwap(_afterSwap(false, true), growthConfig).quoteTakeBps, 0);
    }

    function test_growthAdmissionWithFundedZeroAddress() public {
        vm.deal(address(0), 1);
        _assertPresetAdmission(module.GROWTH_PRESET(), 100, 0);
    }

    function test_allPresetsAdmitTheirPreparedConfig() public {
        _assertPresetAdmission(module.GROWTH_PRESET(), 100, 0);
        _assertPresetAdmission(module.BALANCED_PRESET(), 75, 25);
        _assertPresetAdmission(module.NEUTRAL_PRESET(), 50, 50);
    }

    function test_admissionRejectsChangedPreparedPreset() public {
        EcoBasketModuleV1.Config memory changed = abi.decode(config, (EcoBasketModuleV1.Config));
        changed.preset = module.NEUTRAL_PRESET();
        bytes memory encoded = abi.encode(changed);
        vm.expectRevert(
            abi.encodeWithSelector(
                EcoBasketModuleV1.ConfigNotPrepared.selector, PoolId.unwrap(poolId), keccak256(encoded)
            )
        );
        module.validateStack(PoolId.unwrap(poolId), address(kernel), SUBJECT, address(0), encoded);
    }

    function test_admissionRejectsEveryChangedConfigField() public {
        for (uint256 word; word < 6; ++word) {
            bytes memory changed = config;
            changed[word * 32 + 31] = bytes1(uint8(changed[word * 32 + 31]) ^ 1);
            vm.expectRevert(
                abi.encodeWithSelector(
                    EcoBasketModuleV1.ConfigNotPrepared.selector, PoolId.unwrap(poolId), keccak256(changed)
                )
            );
            module.validateStack(PoolId.unwrap(poolId), address(kernel), SUBJECT, address(0), changed);
        }
    }

    function test_admissionRejectsUnpreparedPool() public {
        bytes32 unpreparedPoolId = keccak256("unprepared");
        vm.expectRevert(
            abi.encodeWithSelector(EcoBasketModuleV1.ConfigNotPrepared.selector, unpreparedPoolId, keccak256(config))
        );
        module.validateStack(unpreparedPoolId, address(kernel), SUBJECT, address(0), config);
    }

    function test_oneWeiSettlementsPreserveDirectionalAllocations() public {
        vm.deal(address(manager), 200);
        kernel.credit(buyStrategy, 100);
        kernel.credit(sellStrategy, 100);
        for (uint256 i; i < 100; ++i) {
            buyStrategy.settleClaims(1);
            sellStrategy.settleClaims(1);
        }
        (uint256 basket, uint256 buyback, uint256 liquidity) = vault.allocations(address(0));
        assertEq(basket, 80);
        assertEq(buyback, 60);
        assertEq(liquidity, 60);
        assertEq(address(vault).balance, basket + buyback + liquidity);
        assertEq(buyStrategy.accountedClaims(), 0);
        assertEq(sellStrategy.accountedClaims(), 0);
    }

    function testFuzz_settlementPartitionsSurviveMarketWithdrawals(uint96 buyAmount, uint96 sellAmount, uint256 seed)
        public
    {
        uint256 buyTotal = uint256(buyAmount) + 1;
        uint256 sellTotal = uint256(sellAmount) + 1;
        vm.deal(address(manager), buyTotal + sellTotal);
        kernel.credit(buyStrategy, buyTotal);
        kernel.credit(sellStrategy, sellTotal);
        uint256 snapshot = vm.snapshotState();
        buyStrategy.settleClaims(buyTotal);
        sellStrategy.settleClaims(sellTotal);
        (uint256 expectedBasket, uint256 expectedBuyback, uint256 expectedLiquidity) = vault.allocations(address(0));
        assertTrue(vm.revertToState(snapshot));

        uint256 buyPart = seed % buyTotal + 1;
        uint256 sellPart = seed % sellTotal + 1;
        buyStrategy.settleClaims(buyPart);
        sellStrategy.settleClaims(sellPart);
        (, uint256 withdrawnBuyback, uint256 withdrawnLiquidity) = vault.allocations(address(0));
        vm.startPrank(EXECUTOR);
        if (withdrawnBuyback != 0) {
            vault.releaseMarketFunds(address(0), EcoBasketModuleVault.MarketAllocation.Buyback, withdrawnBuyback);
        }
        if (withdrawnLiquidity != 0) {
            vault.releaseMarketFunds(address(0), EcoBasketModuleVault.MarketAllocation.Liquidity, withdrawnLiquidity);
        }
        vm.stopPrank();
        if (buyPart < buyTotal) buyStrategy.settleClaims(buyTotal - buyPart);
        if (sellPart < sellTotal) sellStrategy.settleClaims(sellTotal - sellPart);
        (uint256 basket, uint256 buyback, uint256 liquidity) = vault.allocations(address(0));
        assertEq(basket, expectedBasket);
        assertEq(buyback + withdrawnBuyback, expectedBuyback);
        assertEq(liquidity + withdrawnLiquidity, expectedLiquidity);
        assertEq(basket + buyback + liquidity, address(vault).balance);
        assertEq(address(vault).balance + withdrawnBuyback + withdrawnLiquidity, buyTotal + sellTotal);
        assertTrue(buyStrategy.accountingInvariant());
        assertTrue(sellStrategy.accountingInvariant());
    }

    function test_maximumSettlementBatchConservesFunds() public {
        uint256 amount = buyStrategy.MAX_WITHDRAWAL_BATCH();
        vm.deal(address(manager), amount);
        kernel.credit(buyStrategy, amount);
        buyStrategy.settleClaims(amount);
        (uint256 basket, uint256 buyback, uint256 liquidity) = vault.allocations(address(0));
        assertEq(basket + buyback + liquidity, amount);
        assertEq(address(vault).balance, amount);
        assertEq(buyStrategy.accountedClaims(), 0);
        assertEq(buyStrategy.claimBalance(), 0);
    }

    function test_dustOrderAdvancesZeroValueStepsAndCompletes() public {
        (EcoBasketModuleVault dustVault, uint256 orderId) = _scheduleDustOrder();
        NarrativeOrderHub hub = registry.orderHub();
        vm.warp(block.timestamp + 32 days);
        uint256 balanceBefore = EXECUTOR.balance;
        vm.startPrank(EXECUTOR);
        for (uint8 i; i < 3; ++i) {
            assertEq(hub.releaseDue(orderId, 8), 0);
            (,,,,,,,,, uint8 releasedSteps, NarrativeOrderHub.Status status) = hub.orders(orderId);
            assertEq(releasedSteps, (i + 1) * 8);
            assertEq(uint8(status), uint8(NarrativeOrderHub.Status.Active));
            assertEq(dustVault.scheduledBasket(address(0)), 1);
        }
        assertEq(hub.releaseDue(orderId, 8), 1);
        vm.stopPrank();
        (,,,,,,,,, uint8 finalSteps, NarrativeOrderHub.Status finalStatus) = hub.orders(orderId);
        assertEq(finalSteps, 32);
        assertEq(uint8(finalStatus), uint8(NarrativeOrderHub.Status.Complete));
        assertEq(dustVault.scheduledBasket(address(0)), 0);
        assertEq(EXECUTOR.balance - balanceBefore, 1);
        assertEq(address(dustVault).balance, 1);
    }

    function test_dustOrderExpiryRestoresBudgetAfterZeroValueSteps() public {
        (EcoBasketModuleVault dustVault, uint256 orderId) = _scheduleDustOrder();
        NarrativeOrderHub hub = registry.orderHub();
        vm.prank(EXECUTOR);
        assertEq(hub.releaseDue(orderId, 8), 0);
        vm.warp(block.timestamp + 32 days + 30 days + 1);
        assertEq(hub.expire(orderId), 1);
        (uint256 basket,,) = dustVault.allocations(address(0));
        assertEq(basket, 1);
        assertEq(dustVault.scheduledBasket(address(0)), 0);
        assertEq(address(dustVault).balance, 2);
    }

    function _assertPresetAdmission(uint8 preset, uint16 buyFee, uint16 sellFee) internal {
        PoolKey memory presetKey = key;
        presetKey.currency1 = Currency.wrap(address(uint160(0x3000 + preset)));
        address[] memory basket = new address[](1);
        basket[0] = BASKET_TOKEN;
        (PoolId id, bytes memory encoded) = registry.preparePool(presetKey, preset, basket, 1 days, 10);
        assertEq(module.validateConfig(encoded), keccak256(encoded));
        HookrModuleTypesV1.ModuleConfigCaps memory caps = module.validateStack(
            PoolId.unwrap(id), address(kernel), Currency.unwrap(presetKey.currency1), address(0), encoded
        );
        assertEq(caps.configHash, keccak256(encoded));
        assertEq(caps.maxSpecifiedQuoteTakeBps, buyFee);
        assertEq(caps.maxUnspecifiedQuoteTakeBps, buyFee);
        assertEq(module.beforeSwap(_swap(true, true), encoded).quoteTakeBps, buyFee);
        assertEq(module.afterSwap(_afterSwap(false, true), encoded).quoteTakeBps, sellFee);
    }

    function _scheduleDustOrder() internal returns (EcoBasketModuleVault dustVault, uint256 orderId) {
        PoolKey memory dustKey = key;
        dustKey.currency1 = Currency.wrap(address(0x4000));
        address[] memory basket = new address[](1);
        basket[0] = BASKET_TOKEN;
        (PoolId id,) = registry.preparePool(dustKey, module.BALANCED_PRESET(), basket, 1 days, 32);
        EcoBasketModuleRegistry.PoolConfig memory prepared = registry.poolConfig(id);
        dustVault = EcoBasketModuleVault(payable(prepared.vault));
        EcoBasketClaimStrategyV1 strategy = EcoBasketClaimStrategyV1(prepared.buyStrategy);
        vm.deal(address(manager), 2);
        kernel.credit(strategy, 2);
        strategy.settleClaims(2);
        vm.prank(EXECUTOR);
        orderId = dustVault.scheduleBasketOrders(address(0));
    }

    function _swap(bool isBuy, bool exactInput) internal pure returns (HookrModuleTypesV1.SwapContext memory context) {
        context.subject = SUBJECT;
        context.isBuy = isBuy;
        context.exactInput = exactInput;
    }

    function _afterSwap(bool isBuy, bool exactInput)
        internal
        pure
        returns (HookrModuleTypesV1.AfterSwapContext memory context)
    {
        context.subject = SUBJECT;
        context.isBuy = isBuy;
        context.exactInput = exactInput;
    }

    function _assertResult(
        HookrModuleTypesV1.ModuleResult memory result,
        uint16 expectedFee,
        address expectedStrategy,
        bytes32 expectedAttribution
    ) internal pure {
        assertEq(result.lpFeeSurchargePips, 0);
        assertEq(result.quoteTakeBps, expectedFee);
        assertEq(result.claimRecipient, expectedStrategy);
        assertEq(result.attributionKey, expectedAttribution);
    }
}
