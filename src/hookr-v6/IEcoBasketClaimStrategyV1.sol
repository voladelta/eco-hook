// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {IHookrClaimSinkV1} from "./IHookrClaimSinkV1.sol";

interface IEcoBasketClaimStrategyV1 is IHookrClaimSinkV1 {
    function kernel() external view returns (address);
    function poolManager() external view returns (IPoolManager);
    function poolId() external view returns (bytes32);
    function quoteCurrency() external view returns (address);
    function isBuy() external view returns (bool);
    function vault() external view returns (address);
    function ecoConfigHash() external view returns (bytes32);
}
