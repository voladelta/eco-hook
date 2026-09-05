// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {EcoBasketClaimStrategyV1} from "./EcoBasketClaimStrategyV1.sol";
import {EcoBasketModuleV1, IHookrKernelPoolManager} from "./EcoBasketModuleV1.sol";
import {EcoBasketModuleVault} from "./EcoBasketModuleVault.sol";
import {NarrativeOrderHub} from "./NarrativeOrderHub.sol";
import {IEcoBasketModuleRegistryV1} from "./hookr-v6/IEcoBasketModuleRegistryV1.sol";

/// @notice Prepares immutable per-pool Eco module strategies, config, and vaults.
contract EcoBasketModuleRegistry {
    using PoolIdLibrary for PoolKey;

    uint24 public constant DYNAMIC_FEE_FLAG = 0x800000;
    uint256 public constant MAX_BASKET_TOKENS = 8;
    uint8 public constant MAX_ORDER_STEPS = 32;
    bytes32 public constant ECO_CONFIG_TYPEHASH = keccak256(
        "EcoBasketConfig(bytes32 poolId,uint8 preset,bytes32 basketHash,uint32 orderInterval,uint8 orderSteps,address executor)"
    );

    struct PoolConfig {
        bool prepared;
        address vault;
        address buyStrategy;
        address sellStrategy;
        bytes32 ecoConfigHash;
        bytes32 moduleConfigHash;
    }

    struct PreparedContracts {
        address vault;
        address buyStrategy;
        address sellStrategy;
        bytes32 ecoConfigHash;
    }

    error OnlyApprovedAdapter(address caller);
    error InvalidDependency();
    error PoolAlreadyPrepared(PoolId poolId);
    error InvalidPool();
    error InvalidBasketLength(uint256 length);
    error InvalidBasketToken(uint256 index);
    error InvalidOrderSchedule();

    address public immutable approvedAdapter;
    address public immutable approvedExecutor;
    NarrativeOrderHub public immutable orderHub;
    EcoBasketModuleV1 public immutable module;

    mapping(PoolId poolId => PoolConfig config) private _poolConfigs;
    mapping(PoolId poolId => bytes config) private _moduleConfigs;
    mapping(address strategy => bool attested) public isStrategy;
    mapping(address vault => bool registered) public isVault;

    event PoolPrepared(
        PoolId indexed poolId,
        address indexed vault,
        address indexed buyStrategy,
        address sellStrategy,
        bytes32 ecoConfigHash,
        bytes32 moduleConfigHash
    );

    constructor(address approvedAdapter_, address approvedExecutor_) {
        if (approvedAdapter_ == address(0) || approvedExecutor_ == address(0)) revert InvalidDependency();
        approvedAdapter = approvedAdapter_;
        approvedExecutor = approvedExecutor_;
        orderHub = new NarrativeOrderHub(address(this), approvedExecutor_);
        module = new EcoBasketModuleV1(IEcoBasketModuleRegistryV1(address(this)));
    }

    function preparePool(
        PoolKey calldata key,
        uint8 preset,
        address[] calldata selectedBasketTokens,
        uint32 orderInterval,
        uint8 orderSteps
    ) external returns (PoolId poolId, bytes memory encodedModuleConfig) {
        if (msg.sender != approvedAdapter) revert OnlyApprovedAdapter(msg.sender);
        if (
            Currency.unwrap(key.currency0) != address(0) || Currency.unwrap(key.currency1) == address(0)
                || address(key.hooks) == address(0) || address(key.hooks).code.length == 0
                || key.fee != DYNAMIC_FEE_FLAG
        ) revert InvalidPool();
        if (preset > module.NEUTRAL_PRESET()) revert InvalidPool();
        _validateBasket(Currency.unwrap(key.currency1), selectedBasketTokens);
        if (orderInterval == 0 || orderSteps == 0 || orderSteps > MAX_ORDER_STEPS) {
            revert InvalidOrderSchedule();
        }

        poolId = key.toId();
        if (_poolConfigs[poolId].prepared) revert PoolAlreadyPrepared(poolId);
        _poolConfigs[poolId].prepared = true;
        PreparedContracts memory prepared =
            _deployContracts(key, poolId, preset, selectedBasketTokens, orderInterval, orderSteps);

        encodedModuleConfig =
            _encodeModuleConfig(preset, prepared.buyStrategy, prepared.sellStrategy, prepared.ecoConfigHash);
        bytes32 configHash = keccak256(encodedModuleConfig);
        _moduleConfigs[poolId] = encodedModuleConfig;
        _poolConfigs[poolId] = PoolConfig({
            prepared: true,
            vault: prepared.vault,
            buyStrategy: prepared.buyStrategy,
            sellStrategy: prepared.sellStrategy,
            ecoConfigHash: prepared.ecoConfigHash,
            moduleConfigHash: configHash
        });
        emit PoolPrepared(
            poolId, prepared.vault, prepared.buyStrategy, prepared.sellStrategy, prepared.ecoConfigHash, configHash
        );
    }

    function _deployContracts(
        PoolKey calldata key,
        PoolId poolId,
        uint8 preset,
        address[] calldata selectedBasketTokens,
        uint32 orderInterval,
        uint8 orderSteps
    ) internal returns (PreparedContracts memory prepared) {
        address kernel = address(key.hooks);
        IPoolManager manager = IHookrKernelPoolManager(kernel).poolManager();
        if (address(manager) == address(0) || address(manager).code.length == 0) revert InvalidPool();

        prepared.ecoConfigHash = keccak256(
            abi.encode(
                ECO_CONFIG_TYPEHASH,
                PoolId.unwrap(poolId),
                preset,
                keccak256(abi.encode(selectedBasketTokens)),
                orderInterval,
                orderSteps,
                approvedExecutor
            )
        );
        EcoBasketModuleVault vault = new EcoBasketModuleVault(
            address(this),
            address(orderHub),
            approvedExecutor,
            poolId,
            Currency.unwrap(key.currency1),
            address(0),
            selectedBasketTokens,
            orderInterval,
            orderSteps,
            prepared.ecoConfigHash
        );
        EcoBasketClaimStrategyV1 buyStrategy = new EcoBasketClaimStrategyV1(
            kernel, manager, PoolId.unwrap(poolId), address(0), true, vault, prepared.ecoConfigHash
        );
        EcoBasketClaimStrategyV1 sellStrategy = EcoBasketClaimStrategyV1(address(0));
        if (preset != module.GROWTH_PRESET()) {
            sellStrategy = new EcoBasketClaimStrategyV1(
                kernel, manager, PoolId.unwrap(poolId), address(0), false, vault, prepared.ecoConfigHash
            );
        }

        prepared.vault = address(vault);
        prepared.buyStrategy = address(buyStrategy);
        prepared.sellStrategy = address(sellStrategy);
        isStrategy[prepared.buyStrategy] = true;
        if (prepared.sellStrategy != address(0)) isStrategy[prepared.sellStrategy] = true;
        isVault[prepared.vault] = true;
        vault.activateSources(prepared.buyStrategy, prepared.sellStrategy);
    }

    function poolConfig(PoolId poolId) external view returns (PoolConfig memory) {
        return _poolConfigs[poolId];
    }

    function moduleConfig(PoolId poolId) external view returns (bytes memory) {
        return _moduleConfigs[poolId];
    }

    function moduleConfigHash(bytes32 poolId) external view returns (bytes32) {
        return _poolConfigs[PoolId.wrap(poolId)].moduleConfigHash;
    }

    function _encodeModuleConfig(uint8 preset, address buyStrategy, address sellStrategy, bytes32 ecoConfigHash)
        internal
        view
        returns (bytes memory)
    {
        return abi.encode(
            EcoBasketModuleV1.Config({
                preset: preset,
                buyStrategy: buyStrategy,
                buyStrategyCodeHash: buyStrategy.codehash,
                sellStrategy: sellStrategy,
                sellStrategyCodeHash: sellStrategy == address(0) ? bytes32(0) : sellStrategy.codehash,
                ecoConfigHash: ecoConfigHash
            })
        );
    }

    function _validateBasket(address strategyToken, address[] calldata selectedBasketTokens) internal pure {
        if (selectedBasketTokens.length == 0 || selectedBasketTokens.length > MAX_BASKET_TOKENS) {
            revert InvalidBasketLength(selectedBasketTokens.length);
        }
        for (uint256 i; i < selectedBasketTokens.length; ++i) {
            if (selectedBasketTokens[i] == address(0) || selectedBasketTokens[i] == strategyToken) {
                revert InvalidBasketToken(i);
            }
            for (uint256 j; j < i; ++j) {
                if (selectedBasketTokens[i] == selectedBasketTokens[j]) revert InvalidBasketToken(i);
            }
        }
    }
}
