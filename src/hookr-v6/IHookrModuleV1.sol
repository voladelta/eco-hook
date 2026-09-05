// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {HookrModuleTypesV1} from "./HookrModuleTypesV1.sol";

/// @notice Read-only Hookr V6 policy-module boundary used by Eco Basket.
interface IHookrModuleV1 {
    function moduleKey() external pure returns (bytes32);
    function moduleVersion() external pure returns (uint32);
    function configSchemaHash() external pure returns (bytes32);
    function validateConfig(bytes calldata config) external view returns (bytes32 configHash);

    function validateStack(bytes32 poolId, address kernel, address subject, address quote, bytes calldata config)
        external
        view
        returns (HookrModuleTypesV1.ModuleConfigCaps memory caps);

    function beforeAddLiquidity(HookrModuleTypesV1.LiquidityContext calldata context, bytes calldata config)
        external
        view
        returns (bool allowed);

    function beforeSwap(HookrModuleTypesV1.SwapContext calldata context, bytes calldata config)
        external
        view
        returns (HookrModuleTypesV1.ModuleResult memory result);

    function afterSwap(HookrModuleTypesV1.AfterSwapContext calldata context, bytes calldata config)
        external
        view
        returns (HookrModuleTypesV1.ModuleResult memory result);
}
