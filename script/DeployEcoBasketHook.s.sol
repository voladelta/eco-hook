// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {EcoBasketHook} from "../src/EcoBasketHook.sol";

/// @notice Mines and deploys the immutable hook. Running this script requires explicit environment input.
contract DeployEcoBasketHookScript is Script {
    function run() external returns (EcoBasketHook hook) {
        IPoolManager manager = IPoolManager(vm.envAddress("ECO_POOL_MANAGER"));
        address approvedAdapter = vm.envAddress("ECO_APPROVED_ADAPTER");
        address approvedExecutor = vm.envAddress("ECO_APPROVED_EXECUTOR");
        uint160 flags =
            uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);
        bytes memory constructorArgs = abi.encode(manager, approvedAdapter, approvedExecutor);
        (address expected, bytes32 salt) =
            HookMiner.find(CREATE2_FACTORY, flags, type(EcoBasketHook).creationCode, constructorArgs);

        vm.startBroadcast();
        hook = new EcoBasketHook{salt: salt}(manager, approvedAdapter, approvedExecutor);
        vm.stopBroadcast();
        require(address(hook) == expected, "unexpected hook address");
    }
}
