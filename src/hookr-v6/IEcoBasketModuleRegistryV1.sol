// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IEcoBasketModuleRegistryV1 {
    function isStrategy(address strategy) external view returns (bool);
    function moduleConfigHash(bytes32 poolId) external view returns (bytes32);
}
