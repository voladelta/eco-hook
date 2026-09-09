// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {HookrModuleCatalogV1} from "hookr/HookrModuleCatalogV1.sol";
import {HookrStackRegistryV1} from "hookr/HookrStackRegistryV1.sol";
import {HookrStackRegistryV2} from "hookr/HookrStackRegistryV2.sol";
import {HookrMarketCoordinatorV5} from "hookr/HookrMarketCoordinatorV5.sol";
import {IHookrStackRegistryV1CoordinatorV3} from "hookr/HookrMarketCoordinatorV3.sol";
import {IHookrStackRegistryV1} from "hookr/interfaces/IHookrStackRegistryV1.sol";
import {HookrModularHookV6} from "hookr/HookrModularHookV6.sol";
import {HookrSwapAccountingKernelV3} from "hookr/HookrSwapAccountingKernelV3.sol";
import {HookrNativeMechanicsBlockV2} from "hookr/HookrNativeMechanicsBlockV2.sol";
import {HookrKernelRouterV3} from "hookr/HookrKernelRouterV3.sol";
import {HookrKernelQuoterV1} from "hookr/HookrKernelQuoterV1.sol";
import {HookrReleaseCreate2FactoryV1} from "hookr/HookrReleaseCreate2FactoryV1.sol";
import {HookrTreasuryForwarderV1} from "hookr/HookrTreasuryForwarderV1.sol";
import {HookrModuleTypesV1} from "hookr/libraries/HookrModuleTypesV1.sol";
import {EcoBasketModuleRegistry} from "eco/src/EcoBasketModuleRegistry.sol";
import {EcoBasketModuleV1} from "eco/src/EcoBasketModuleV1.sol";
import {EcoBasketClaimStrategyV1} from "eco/src/EcoBasketClaimStrategyV1.sol";
import {EcoBasketModuleVault} from "eco/src/EcoBasketModuleVault.sol";
import {EcoHookrTestLauncher} from "../src/EcoHookrTestLauncher.sol";

abstract contract HookrLocalFixture is Test {
    using PoolIdLibrary for PoolKey;

    uint160 internal constant HOOK_FLAGS = 0x28cc;
    uint160 internal constant PRICE_ONE = 79228162514264337593543950336;
    uint32 internal constant NATIVE_GAS = 1_000_000;
    uint32 internal constant ECO_GAS = 400_000;
    address internal constant TREASURY = address(0x7000);
    address internal constant EXECUTOR = address(0xE000);
    address internal constant TRADER = address(0xA11CE);
    address internal constant RECIPIENT = address(0xB0B);

    PoolManager internal manager;
    HookrModuleCatalogV1 internal catalog;
    HookrStackRegistryV2 internal stacks;
    HookrMarketCoordinatorV5 internal coordinator;
    HookrModularHookV6 internal hook;
    HookrNativeMechanicsBlockV2 internal nativeBlock;
    HookrKernelRouterV3 internal router;
    HookrKernelQuoterV1 internal quoter;
    HookrTreasuryForwarderV1 internal treasury;
    PoolModifyLiquidityTest internal liquidityRouter;
    EcoHookrTestLauncher internal launcher;
    EcoBasketModuleRegistry internal eco;
    EcoBasketModuleV1 internal ecoModule;
    MockERC20 internal subject;
    MockERC20 internal basket;
    bytes32 internal kernelId;
    bytes32 internal nativeModuleId;
    bytes32 internal ecoModuleId;
    bytes32 internal routerId;
    bytes32 internal quoterId;

    struct EcoPool {
        PoolKey key;
        EcoBasketModuleVault vault;
        EcoBasketClaimStrategyV1 buy;
        EcoBasketClaimStrategyV1 sell;
    }

    receive() external payable {}

    function setUp() public virtual {
        manager = _createManager();
        vm.deal(address(this), 100_000 ether);
        vm.deal(TRADER, 100 ether);
        treasury = new HookrTreasuryForwarderV1(address(this), TREASURY, address(manager));
        catalog = new HookrModuleCatalogV1(address(this));
        stacks = HookrStackRegistryV2(
            deployCode(
                "HookrStackRegistryV2.sol:HookrStackRegistryV2", abi.encode(address(this), manager, catalog)
            )
        );
        coordinator = HookrMarketCoordinatorV5(
            payable(deployCode(
                    "HookrMarketCoordinatorV5.sol:HookrMarketCoordinatorV5",
                    abi.encode(address(this), manager, stacks, treasury)
                ))
        );
        stacks.setCoordinatorOnce(address(coordinator));
        coordinator.setMarketOpeningPaused(false);
        _deployRoot();

        nativeBlock = HookrNativeMechanicsBlockV2(
            payable(deployCode(
                    "HookrNativeMechanicsBlockV2.sol:HookrNativeMechanicsBlockV2",
                    abi.encode(manager, stacks, treasury)
                ))
        );
        treasury.setNativeBlock(address(nativeBlock));
        catalog.setCanonicalStatefulModuleOnce(address(nativeBlock));
        nativeModuleId = catalog.registerModule(_nativeRegistration());

        launcher = new EcoHookrTestLauncher(coordinator, nativeModuleId, EXECUTOR);
        eco = launcher.eco();
        ecoModule = eco.module();
        ecoModuleId = catalog.registerModule(_ecoRegistration());
        _registerRouting();
        _sealProfile(_includeEcoInProfile());

        subject = new MockERC20("Local subject", "SUB", 18);
        basket = new MockERC20("Local basket asset", "BSK", 18);
        subject.mint(address(this), 100_000 ether);
        subject.mint(TRADER, 100 ether);
        liquidityRouter = new PoolModifyLiquidityTest(manager);
        subject.approve(address(liquidityRouter), type(uint256).max);
        vm.prank(TRADER);
        subject.approve(address(router), type(uint256).max);
    }

    function _createManager() internal virtual returns (PoolManager) {
        return PoolManager(deployCode("PoolManager.sol:PoolManager", abi.encode(address(this))));
    }

    function _includeEcoInProfile() internal pure virtual returns (bool) {
        return true;
    }

    function _assertNoStack(PoolId poolId) internal {
        vm.expectRevert(abi.encodeWithSelector(HookrStackRegistryV1.UnknownStack.selector, poolId));
        stacks.stack(poolId);
    }

    function _deployRoot() internal {
        address accounting = deployCode(
            "HookrSwapAccountingKernelV3.sol:HookrSwapAccountingKernelV3",
            abi.encode(manager, stacks, coordinator)
        );
        HookrReleaseCreate2FactoryV1 factory = new HookrReleaseCreate2FactoryV1();
        bytes memory initCode = abi.encodePacked(
            vm.getCode("HookrModularHookV6.sol:HookrModularHookV6"),
            abi.encode(manager, stacks, coordinator, accounting)
        );
        bytes32 hash = keccak256(initCode);
        for (uint256 salt; salt < 1_000_000; ++salt) {
            address predicted = factory.computeAddress(bytes32(salt), hash);
            if (uint160(predicted) & 0x3fff == HOOK_FLAGS) {
                hook = HookrModularHookV6(payable(factory.deploy(bytes32(salt), initCode)));
                break;
            }
        }
        assertTrue(address(hook) != address(0), "CREATE2 hook mining exhausted");
        kernelId = stacks.registerKernel(
            HookrStackRegistryV1.KernelRegistration({
                kernelFamilyId: keccak256("HOOKR_SWAP_DELTA_V1"),
                version: 6,
                implementation: address(hook),
                hookFlags: HOOK_FLAGS
            })
        );
    }

    function _registerRouting() internal {
        router = HookrKernelRouterV3(
            payable(deployCode(
                    "HookrKernelRouterV3.sol:HookrKernelRouterV3", abi.encode(manager, stacks, coordinator)
                ))
        );
        quoter = new HookrKernelQuoterV1(manager, IHookrStackRegistryV1(address(stacks)));
        routerId = stacks.registerIntegration(
            HookrStackRegistryV1.IntegrationRegistration(
                router.integrationKind(),
                router.integrationFamilyId(),
                router.integrationVersion(),
                address(router)
            )
        );
        quoterId = stacks.registerIntegration(
            HookrStackRegistryV1.IntegrationRegistration(
                quoter.integrationKind(),
                quoter.integrationFamilyId(),
                quoter.integrationVersion(),
                address(quoter)
            )
        );
    }

    function _sealProfile(bool includeEco) internal {
        bytes32[] memory ids = new bytes32[](includeEco ? 2 : 1);
        ids[0] = nativeModuleId;
        if (includeEco) {
            ids[1] = ecoModuleId;
            if (ids[0] > ids[1]) (ids[0], ids[1]) = (ids[1], ids[0]);
        }
        stacks.sealRootProfile(
            kernelId, keccak256("ECO_LOCAL_TEST_PROFILE"), 1, ids, routerId, quoterId, bytes32(0), false
        );
    }

    function _nativeRegistration() internal view returns (HookrModuleTypesV1.ModuleRegistration memory reg) {
        reg.moduleKey = nativeBlock.moduleKey();
        reg.version = nativeBlock.moduleVersion();
        reg.implementation = address(nativeBlock);
        reg.configSchemaHash = nativeBlock.configSchemaHash();
        reg.requiredHookFlags = HOOK_FLAGS;
        reg.phaseMask = nativeBlock.phaseMask();
        reg.exclusiveGroup = nativeBlock.exclusiveGroup();
        reg.executionMode = HookrModuleTypesV1.ExecutionMode.STATEFUL_V1;
        reg.maxLpFeeSurchargePips = 497_000;
        reg.maxSpecifiedQuoteTakeBps = 3_500;
        reg.maxUnspecifiedQuoteTakeBps = 2_500;
        reg.maxSubjectTakeBps = 1_000;
        reg.callbackGasLimit = NATIVE_GAS;
        reg.requiredModuleKeys = new bytes32[](0);
        reg.conflictingModuleKeys = new bytes32[](0);
    }

    function _ecoRegistration() internal view returns (HookrModuleTypesV1.ModuleRegistration memory reg) {
        reg.moduleKey = ecoModule.moduleKey();
        reg.version = ecoModule.moduleVersion();
        reg.implementation = address(ecoModule);
        reg.configSchemaHash = ecoModule.configSchemaHash();
        reg.requiredHookFlags = HOOK_FLAGS;
        reg.phaseMask = ecoModule.phaseMask();
        reg.exclusiveGroup = ecoModule.exclusiveGroup();
        reg.executionMode = HookrModuleTypesV1.ExecutionMode.READ_ONLY;
        reg.maxSpecifiedQuoteTakeBps = 100;
        reg.maxUnspecifiedQuoteTakeBps = 100;
        reg.callbackGasLimit = ECO_GAS;
        reg.requiredModuleKeys = new bytes32[](1);
        reg.requiredModuleKeys[0] = nativeBlock.moduleKey();
        reg.conflictingModuleKeys = new bytes32[](0);
    }

    function _market() internal view returns (HookrMarketCoordinatorV5.MarketParams memory market) {
        market.tickSpacing = 60;
        market.sqrtPriceX96 = PRICE_ONE;
        market.kernelId = kernelId;
        market.limits.baseLpFeePips = 3_000;
        market.limits.maxLpFeePips = 500_000;
        market.limits.maxSpecifiedQuoteTakeBps = 3_600;
        market.limits.maxUnspecifiedQuoteTakeBps = 2_600;
        market.limits.maxSubjectTakeBps = 1_000;
        market.limits.maxTotalModuleGas = NATIVE_GAS + ECO_GAS;
        market.limits.trustedRouter = address(router);
        market.limits.trustedQuoter = address(quoter);
    }

    function _nativeConfig() internal pure returns (HookrNativeMechanicsBlockV2.Config memory cfg) {
        cfg.baseFeePips = 3_000;
        cfg.maxFeePips = 3_000;
    }

    function _settings(uint8 preset)
        internal
        view
        returns (EcoHookrTestLauncher.EcoSettings memory settings)
    {
        settings.preset = preset;
        settings.basket = new address[](1);
        settings.basket[0] = address(basket);
        settings.interval = 1 days;
        settings.steps = 10;
    }

    function _openExisting(uint8 preset, HookrNativeMechanicsBlockV2.Config memory cfg)
        internal
        returns (EcoPool memory pool)
    {
        HookrMarketCoordinatorV5.ExistingTokenArgs memory args =
            HookrMarketCoordinatorV5.ExistingTokenArgs(address(subject), _market());
        PoolId poolId = launcher.openExisting(args, cfg, _settings(preset), ecoModuleId);
        pool = _ecoPool(coordinator.poolKeyFor(address(subject), args.market));
        assertEq(PoolId.unwrap(pool.key.toId()), PoolId.unwrap(poolId));

        liquidityRouter.modifyLiquidity{value: 100 ether}(
            pool.key,
            ModifyLiquidityParams({
                tickLower: -600, tickUpper: 600, liquidityDelta: 1_000 ether, salt: bytes32(0)
            }),
            hex""
        );
    }

    function _ecoPool(PoolKey memory key) internal view returns (EcoPool memory pool) {
        EcoBasketModuleRegistry.PoolConfig memory config = eco.poolConfig(key.toId());
        pool.key = key;
        pool.vault = EcoBasketModuleVault(payable(config.vault));
        pool.buy = EcoBasketClaimStrategyV1(config.buyStrategy);
        pool.sell = EcoBasketClaimStrategyV1(config.sellStrategy);
    }

    function _inputParams(PoolKey memory key, bool buy, uint128 amount)
        internal
        view
        returns (HookrKernelRouterV3.ExactInputParams memory)
    {
        return HookrKernelRouterV3.ExactInputParams({
            key: key,
            zeroForOne: buy,
            amountIn: amount,
            amountOutMinimum: 1,
            sqrtPriceLimitX96: buy ? router.MIN_SQRT_PRICE_LIMIT() : router.MAX_SQRT_PRICE_LIMIT(),
            recipient: RECIPIENT,
            deadline: block.timestamp
        });
    }

    function _outputParams(PoolKey memory key, bool buy, uint128 amount)
        internal
        view
        returns (HookrKernelRouterV3.ExactOutputParams memory)
    {
        return HookrKernelRouterV3.ExactOutputParams({
            key: key,
            zeroForOne: buy,
            amountOut: amount,
            amountInMaximum: 2 ether,
            sqrtPriceLimitX96: buy ? router.MIN_SQRT_PRICE_LIMIT() : router.MAX_SQRT_PRICE_LIMIT(),
            recipient: RECIPIENT,
            deadline: block.timestamp
        });
    }
}
