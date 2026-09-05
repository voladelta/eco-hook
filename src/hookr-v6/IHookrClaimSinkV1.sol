// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Sink for quote-currency ERC-6909 claims minted by a Hookr kernel.
interface IHookrClaimSinkV1 {
    function canCredit(uint256 amount) external view returns (bool);
    function creditClaims(uint256 amount) external;
}
