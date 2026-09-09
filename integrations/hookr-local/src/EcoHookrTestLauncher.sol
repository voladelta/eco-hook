// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrMarketCoordinatorV5} from "hookr/HookrMarketCoordinatorV5.sol";
import {HookrNativeMechanicsBlockV2} from "hookr/HookrNativeMechanicsBlockV2.sol";
import {HookrModuleTypesV1} from "hookr/libraries/HookrModuleTypesV1.sol";
import {EcoBasketModuleRegistry} from "eco/src/EcoBasketModuleRegistry.sol";

/// @notice Local integration prototype, restricted to its deploying test operator.
/// @dev Demonstrates preparation and current coordinator ordering. Not a production launcher API.
contract EcoHookrTestLauncher {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    struct EcoSettings {
        uint8 preset;
        address[] basket;
        uint32 interval;
        uint8 steps;
    }

    address public immutable operator;
    HookrMarketCoordinatorV5 public immutable coordinator;
    EcoBasketModuleRegistry public immutable eco;
    bytes32 public immutable nativeModuleId;

    error OnlyOperator();
    error PreparedConfigMismatch();
    error WrongEcoModule();

    modifier onlyOperator() {
        if (msg.sender != operator) revert OnlyOperator();
        _;
    }

    constructor(HookrMarketCoordinatorV5 coordinator_, bytes32 nativeModuleId_, address executor) {
        operator = msg.sender;
        coordinator = coordinator_;
        nativeModuleId = nativeModuleId_;
        eco = new EcoBasketModuleRegistry(address(this), executor);
    }

    function prepare(PoolKey calldata key, EcoSettings calldata settings)
        external
        onlyOperator
        returns (bytes memory config)
    {
        return _prepare(key, settings);
    }

    function openExisting(
        HookrMarketCoordinatorV5.ExistingTokenArgs memory args,
        HookrNativeMechanicsBlockV2.Config memory nativeConfig,
        EcoSettings calldata settings,
        bytes32 ecoModuleId
    ) external onlyOperator returns (PoolId poolId) {
        args.market = _completeMarket(args.subject, args.market, nativeConfig, settings, ecoModuleId);
        return coordinator.openExistingTokenMarket(args);
    }

    function openNew(
        HookrMarketCoordinatorV5.NewTokenArgs memory args,
        bytes32 intentId,
        HookrNativeMechanicsBlockV2.Config memory nativeConfig,
        EcoSettings calldata settings,
        bytes32 ecoModuleId
    ) external payable onlyOperator returns (address subject, PoolId poolId) {
        args.expectedCreator = address(this);
        address expectedToken = coordinator.previewNewTokenAddress(args, intentId);
        args.market = _completeMarket(expectedToken, args.market, nativeConfig, settings, ecoModuleId);
        (subject, poolId) = coordinator.openNewTokenMarket{value: msg.value}(args, intentId, expectedToken);

        // The launcher is Hookr's creator; deliver its optional creator-buy output to the operator.
        Currency token = Currency.wrap(subject);
        uint256 received = token.balanceOfSelf();
        if (received != 0) token.transfer(operator, received);
    }

    function _completeMarket(
        address subject,
        HookrMarketCoordinatorV5.MarketParams memory market,
        HookrNativeMechanicsBlockV2.Config memory nativeConfig,
        EcoSettings calldata settings,
        bytes32 ecoModuleId
    ) internal returns (HookrMarketCoordinatorV5.MarketParams memory) {
        HookrModuleTypesV1.ModuleSnapshot memory selected = coordinator.stackRegistry().module(ecoModuleId);
        if (selected.implementation != address(eco.module())) revert WrongEcoModule();

        PoolKey memory key = coordinator.poolKeyFor(subject, market);
        bytes memory ecoConfig = _prepare(key, settings);

        nativeConfig.poolId = PoolId.unwrap(key.toId());
        nativeConfig.kernel = address(key.hooks);
        nativeConfig.subject = subject;
        nativeConfig.quote = market.quote;
        nativeConfig.protocolRecipient = coordinator.treasuryBeneficiary();
        nativeConfig.protocolShareBps = coordinator.protocolShareBps(address(this));

        market.modules = new HookrModuleTypesV1.ModuleSelection[](2);
        market.modules[0] = HookrModuleTypesV1.ModuleSelection(nativeModuleId, abi.encode(nativeConfig));
        market.modules[1] = HookrModuleTypesV1.ModuleSelection(ecoModuleId, ecoConfig);
        return market;
    }

    function _prepare(PoolKey memory key, EcoSettings calldata settings)
        internal
        returns (bytes memory config)
    {
        PoolId poolId = key.toId();
        EcoBasketModuleRegistry.PoolConfig memory prepared = eco.poolConfig(poolId);
        if (!prepared.prepared) {
            (, config) =
                eco.preparePool(key, settings.preset, settings.basket, settings.interval, settings.steps);
            return config;
        }

        // A separate preparation may be retried only with the identical Eco commitment.
        bytes32 expected = keccak256(
            abi.encode(
                eco.ECO_CONFIG_TYPEHASH(),
                poolId,
                settings.preset,
                keccak256(abi.encode(settings.basket)),
                settings.interval,
                settings.steps,
                eco.approvedExecutor()
            )
        );
        if (prepared.ecoConfigHash != expected) revert PreparedConfigMismatch();
        return eco.moduleConfig(poolId);
    }
}
