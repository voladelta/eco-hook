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
