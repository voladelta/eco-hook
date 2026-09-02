// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {EcoVault} from "./EcoVault.sol";
import {NarrativeOrderHub} from "./NarrativeOrderHub.sol";

/// @notice Stores the immutable configuration selected before a Hookr pool is initialized.
contract EcoPoolRegistry {
    using PoolIdLibrary for PoolKey;

    enum Preset {
        Growth,
        Balanced,
        Neutral
    }

    struct PoolConfig {
        uint16 buyFeeBps;
        uint16 sellFeeBps;
        uint32 orderInterval;
        uint8 orderSteps;
        bool prepared;
        bool active;
        address vault;
    }

    error OnlyApprovedAdapter(address caller);
    error OnlyHook(address caller);
    error PoolAlreadyPrepared(PoolId poolId);
    error PoolNotPrepared(PoolId poolId);
    error PoolAlreadyActive(PoolId poolId);
    error InvalidPoolOrientation();
    error InvalidDependency();
    error InvalidBasketLength(uint256 length);
    error InvalidBasketToken(uint256 index);
    error InvalidOrderSchedule();

    uint256 public constant MAX_BASKET_TOKENS = 8;
    uint8 public constant MAX_ORDER_STEPS = 32;

    address public immutable hook;
    address public immutable approvedAdapter;
    address public immutable approvedExecutor;
    NarrativeOrderHub public immutable orderHub;

    mapping(PoolId poolId => PoolConfig config) private _configs;
    mapping(PoolId poolId => address[] tokens) private _basketTokens;
    mapping(address vault => bool registered) public isVault;

    constructor(address hook_, address approvedAdapter_, address approvedExecutor_) {
        if (hook_ == address(0) || approvedAdapter_ == address(0) || approvedExecutor_ == address(0)) {
            revert InvalidDependency();
        }
        hook = hook_;
        approvedAdapter = approvedAdapter_;
        approvedExecutor = approvedExecutor_;
        orderHub = new NarrativeOrderHub(address(this), approvedExecutor_);
    }

    /// @notice Prepares one pool. The adapter is an immutable integration boundary, not a router ABI.
    function preparePool(
        PoolKey calldata key,
        Preset preset,
        address[] calldata selectedBasketTokens,
        uint32 orderInterval,
        uint8 orderSteps
    ) external returns (PoolId poolId, address vault) {
        if (msg.sender != approvedAdapter) revert OnlyApprovedAdapter(msg.sender);
        if (
            Currency.unwrap(key.currency0) != address(0) || Currency.unwrap(key.currency1) == address(0)
                || address(key.hooks) != hook
        ) revert InvalidPoolOrientation();
        if (selectedBasketTokens.length == 0 || selectedBasketTokens.length > MAX_BASKET_TOKENS) {
            revert InvalidBasketLength(selectedBasketTokens.length);
        }
        if (orderInterval == 0 || orderSteps == 0 || orderSteps > MAX_ORDER_STEPS) revert InvalidOrderSchedule();

        poolId = key.toId();
        if (_configs[poolId].prepared) revert PoolAlreadyPrepared(poolId);

        for (uint256 i; i < selectedBasketTokens.length; ++i) {
            if (selectedBasketTokens[i] == address(0) || selectedBasketTokens[i] == Currency.unwrap(key.currency1)) {
                revert InvalidBasketToken(i);
            }
            for (uint256 j; j < i; ++j) {
                if (selectedBasketTokens[i] == selectedBasketTokens[j]) revert InvalidBasketToken(i);
            }
            _basketTokens[poolId].push(selectedBasketTokens[i]);
        }

        (uint16 buyFeeBps, uint16 sellFeeBps) = feesForPreset(preset);
        vault = address(
            new EcoVault(
                hook,
                address(orderHub),
                approvedExecutor,
                poolId,
                Currency.unwrap(key.currency1),
                selectedBasketTokens,
                orderInterval,
                orderSteps
            )
        );
        _configs[poolId] = PoolConfig({
            buyFeeBps: buyFeeBps,
            sellFeeBps: sellFeeBps,
            orderInterval: orderInterval,
            orderSteps: orderSteps,
            prepared: true,
            active: false,
            vault: vault
        });
        isVault[vault] = true;
    }

    function activatePool(PoolKey calldata key) external returns (PoolConfig memory activatedConfig) {
        if (msg.sender != hook) revert OnlyHook(msg.sender);
        PoolId poolId = key.toId();
        activatedConfig = _configs[poolId];
        if (!activatedConfig.prepared) revert PoolNotPrepared(poolId);
        if (activatedConfig.active) revert PoolAlreadyActive(poolId);
        _configs[poolId].active = true;
        activatedConfig.active = true;
    }

    function config(PoolId poolId) external view returns (PoolConfig memory) {
        return _configs[poolId];
    }

    function basketTokens(PoolId poolId) external view returns (address[] memory) {
        return _basketTokens[poolId];
    }

    function feesForPreset(Preset preset) public pure returns (uint16 buyFeeBps, uint16 sellFeeBps) {
        if (preset == Preset.Growth) return (100, 0);
        if (preset == Preset.Balanced) return (75, 25);
        return (50, 50);
    }
}
