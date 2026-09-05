// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IEcoBasketModuleRegistryV1 {
    function isStrategy(address strategy) external view returns (bool);
}
