// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {IEcoBasketClaimStrategyV1} from "./hookr-v6/IEcoBasketClaimStrategyV1.sol";
import {IEcoBasketModuleRegistryV1} from "./hookr-v6/IEcoBasketModuleRegistryV1.sol";
import {IHookrModuleV1} from "./hookr-v6/IHookrModuleV1.sol";
import {HookrModuleTypesV1} from "./hookr-v6/HookrModuleTypesV1.sol";

interface IHookrKernelPoolManager {
    function poolManager() external view returns (IPoolManager);
}

/// @notice Typed Eco quote-fee policy for Hookr's read-only V6 module lane.
contract EcoBasketModuleV1 is IHookrModuleV1 {
    uint8 public constant GROWTH_PRESET = 0;
    uint8 public constant BALANCED_PRESET = 1;
    uint8 public constant NEUTRAL_PRESET = 2;
    uint16 public constant MAX_FEE_BPS = 100;
    uint32 public constant MODULE_VERSION = 1;
    uint8 public constant PHASE_MASK = HookrModuleTypesV1.PHASE_BEFORE_SWAP | HookrModuleTypesV1.PHASE_AFTER_SWAP;
    bytes32 public constant MODULE_KEY = keccak256("ECO_BASKET_QUOTE_FEE");
    bytes32 public constant EXCLUSIVE_GROUP = keccak256("DIRECTIONAL_QUOTE_TAX");
    bytes32 public constant CONFIG_SCHEMA_HASH = keccak256(
        "EcoBasketModuleV1.Config(uint8 preset,address buyStrategy,bytes32 buyStrategyCodeHash,address sellStrategy,bytes32 sellStrategyCodeHash,bytes32 ecoConfigHash)"
    );
    bytes32 public constant BUY_ATTRIBUTION_KEY = keccak256("ECO_BASKET_QUOTE_FEE_BUY");
    bytes32 public constant SELL_ATTRIBUTION_KEY = keccak256("ECO_BASKET_QUOTE_FEE_SELL");

    struct Config {
        uint8 preset;
        address buyStrategy;
        bytes32 buyStrategyCodeHash;
        address sellStrategy;
        bytes32 sellStrategyCodeHash;
        bytes32 ecoConfigHash;
    }

    IEcoBasketModuleRegistryV1 public immutable strategyRegistry;

    error InvalidRegistry();
    error InvalidConfig();
    error ConfigNotPrepared(bytes32 poolId, bytes32 configHash);
    error StrategyNotAttested(address strategy);
    error StrategyCodeChanged(address strategy, bytes32 expected, bytes32 actual);
    error StrategyBindingMismatch(address strategy);
    error StrategyUnavailable(address strategy);

    constructor(IEcoBasketModuleRegistryV1 strategyRegistry_) {
        if (address(strategyRegistry_) == address(0)) revert InvalidRegistry();
        strategyRegistry = strategyRegistry_;
    }

    function contractName() external pure returns (string memory) {
        return "EcoBasketModuleV1";
    }

    function contractVersion() external pure returns (string memory) {
        return "1.0.0";
    }

    function moduleKey() external pure override returns (bytes32) {
        return MODULE_KEY;
    }

    function moduleVersion() external pure override returns (uint32) {
        return MODULE_VERSION;
    }

    function configSchemaHash() external pure override returns (bytes32) {
        return CONFIG_SCHEMA_HASH;
    }

    function phaseMask() external pure returns (uint8) {
        return PHASE_MASK;
    }

    function exclusiveGroup() external pure returns (bytes32) {
        return EXCLUSIVE_GROUP;
    }

    function feesForPreset(uint8 preset) public pure returns (uint16 buyFeeBps, uint16 sellFeeBps) {
        if (preset == GROWTH_PRESET) return (100, 0);
        if (preset == BALANCED_PRESET) return (75, 25);
        if (preset == NEUTRAL_PRESET) return (50, 50);
        revert InvalidConfig();
    }

    function validateConfig(bytes calldata config) external view override returns (bytes32 configHash) {
        Config memory decoded = _decodeAndValidate(config);
        _validateConfiguredStrategies(decoded);
        return keccak256(config);
    }

    function validateStack(bytes32 poolId, address kernel, address subject, address quote, bytes calldata config)
        external
        view
        override
        returns (HookrModuleTypesV1.ModuleConfigCaps memory caps)
    {
        if (
            poolId == bytes32(0) || kernel == address(0) || kernel.code.length == 0 || subject == address(0)
                || subject == quote
        ) revert InvalidConfig();
        bytes32 configHash = keccak256(config);
        if (strategyRegistry.moduleConfigHash(poolId) != configHash) revert ConfigNotPrepared(poolId, configHash);
        Config memory decoded = _decodeAndValidate(config);
        IPoolManager manager = IHookrKernelPoolManager(kernel).poolManager();
        _validateStrategyBinding(
            decoded.buyStrategy,
            decoded.buyStrategyCodeHash,
            kernel,
            manager,
            poolId,
            quote,
            true,
            decoded.ecoConfigHash
        );
        if (decoded.sellStrategy != address(0)) {
            _validateStrategyBinding(
                decoded.sellStrategy,
                decoded.sellStrategyCodeHash,
                kernel,
                manager,
                poolId,
                quote,
                false,
                decoded.ecoConfigHash
            );
        }

        (uint16 buyFeeBps, uint16 sellFeeBps) = feesForPreset(decoded.preset);
        uint16 maximum = buyFeeBps > sellFeeBps ? buyFeeBps : sellFeeBps;
        caps.configHash = configHash;
        caps.maxSpecifiedQuoteTakeBps = maximum;
        caps.maxUnspecifiedQuoteTakeBps = maximum;
    }

    function beforeAddLiquidity(HookrModuleTypesV1.LiquidityContext calldata, bytes calldata)
        external
        pure
        override
        returns (bool allowed)
    {
        return true;
    }

    function beforeSwap(HookrModuleTypesV1.SwapContext calldata context, bytes calldata config)
        external
        view
        override
        returns (HookrModuleTypesV1.ModuleResult memory result)
    {
        Config memory decoded = _decodeAndValidate(config);
        _validateConfiguredStrategies(decoded);
        (uint16 buyFeeBps, uint16 sellFeeBps) = feesForPreset(decoded.preset);
        if (context.isBuy && context.exactInput) {
            return _result(decoded.buyStrategy, buyFeeBps, BUY_ATTRIBUTION_KEY);
        }
        if (!context.isBuy && !context.exactInput) {
            return _result(decoded.sellStrategy, sellFeeBps, SELL_ATTRIBUTION_KEY);
        }
    }

    function afterSwap(HookrModuleTypesV1.AfterSwapContext calldata context, bytes calldata config)
        external
        view
        override
        returns (HookrModuleTypesV1.ModuleResult memory result)
    {
        Config memory decoded = _decodeAndValidate(config);
        _validateConfiguredStrategies(decoded);
        (uint16 buyFeeBps, uint16 sellFeeBps) = feesForPreset(decoded.preset);
        if (context.isBuy && !context.exactInput) {
            return _result(decoded.buyStrategy, buyFeeBps, BUY_ATTRIBUTION_KEY);
        }
        if (!context.isBuy && context.exactInput) {
            return _result(decoded.sellStrategy, sellFeeBps, SELL_ATTRIBUTION_KEY);
        }
    }

    function _decodeAndValidate(bytes calldata config) internal pure returns (Config memory decoded) {
        if (config.length != 192) revert InvalidConfig();
        decoded = abi.decode(config, (Config));
        if (keccak256(config) != keccak256(abi.encode(decoded)) || decoded.ecoConfigHash == bytes32(0)) {
            revert InvalidConfig();
        }
        (, uint16 sellFeeBps) = feesForPreset(decoded.preset);
        if (decoded.buyStrategy == address(0) || decoded.buyStrategyCodeHash == bytes32(0)) revert InvalidConfig();
        if (sellFeeBps == 0) {
            if (decoded.sellStrategy != address(0) || decoded.sellStrategyCodeHash != bytes32(0)) {
                revert InvalidConfig();
            }
        } else if (decoded.sellStrategy == address(0) || decoded.sellStrategyCodeHash == bytes32(0)) {
            revert InvalidConfig();
        }
    }

    function _validateConfiguredStrategies(Config memory config) internal view {
        _validateStrategyIdentity(config.buyStrategy, config.buyStrategyCodeHash, true);
        if (config.sellStrategy != address(0)) {
            _validateStrategyIdentity(config.sellStrategy, config.sellStrategyCodeHash, false);
        }
    }

    function _validateStrategyIdentity(address strategy, bytes32 expectedCodeHash, bool expectedBuy) internal view {
        if (!strategyRegistry.isStrategy(strategy)) revert StrategyNotAttested(strategy);
        bytes32 actualCodeHash = strategy.codehash;
        if (actualCodeHash != expectedCodeHash) {
            revert StrategyCodeChanged(strategy, expectedCodeHash, actualCodeHash);
        }
        if (IEcoBasketClaimStrategyV1(strategy).isBuy() != expectedBuy) {
            revert StrategyBindingMismatch(strategy);
        }
    }

    function _validateStrategyBinding(
        address strategy,
        bytes32 expectedCodeHash,
        address kernel,
        IPoolManager manager,
        bytes32 poolId,
        address quote,
        bool expectedBuy,
        bytes32 ecoConfigHash
    ) internal view {
        _validateStrategyIdentity(strategy, expectedCodeHash, expectedBuy);
        IEcoBasketClaimStrategyV1 candidate = IEcoBasketClaimStrategyV1(strategy);
        if (
            candidate.kernel() != kernel || address(candidate.poolManager()) != address(manager)
                || candidate.poolId() != poolId || candidate.quoteCurrency() != quote
                || candidate.ecoConfigHash() != ecoConfigHash
        ) revert StrategyBindingMismatch(strategy);
        if (!candidate.canCredit(1)) revert StrategyUnavailable(strategy);
    }

    function _result(address strategy, uint16 feeBps, bytes32 attributionKey)
        internal
        pure
        returns (HookrModuleTypesV1.ModuleResult memory result)
    {
        if (feeBps == 0) return result;
        result.quoteTakeBps = feeBps;
        result.claimRecipient = strategy;
        result.attributionKey = attributionKey;
    }
}
