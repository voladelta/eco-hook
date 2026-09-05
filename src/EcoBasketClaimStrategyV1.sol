// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {EcoBasketModuleVault} from "./EcoBasketModuleVault.sol";
import {IEcoBasketClaimStrategyV1} from "./hookr-v6/IEcoBasketClaimStrategyV1.sol";

/// @notice Direction-bound Hookr claim sink that settles quote directly into an Eco vault.
contract EcoBasketClaimStrategyV1 is IEcoBasketClaimStrategyV1, IUnlockCallback {
    uint256 public constant MAX_WITHDRAWAL_BATCH = uint256(uint128(type(int128).max));

    address public immutable override kernel;
    IPoolManager public immutable override poolManager;
    bytes32 public immutable override poolId;
    address public immutable override quoteCurrency;
    bool public immutable override isBuy;
    address public immutable override vault;
    bytes32 public immutable override ecoConfigHash;

    uint256 public accountedClaims;
    uint256 public cumulativeClaimsCredited;
    uint256 public cumulativeClaimsSettled;

    bool private withdrawingClaims;
    uint256 private reentrancyState = 1;

    event ClaimsCredited(bytes32 indexed poolId, bool indexed isBuy, uint256 amount, uint256 outstandingClaims);
    event ClaimsSettled(
        bytes32 indexed poolId, bool indexed isBuy, address indexed vault, uint256 amount, uint256 outstandingClaims
    );

    error InvalidDependency();
    error NotKernel(address caller);
    error NotPoolManager(address caller);
    error InvalidUnlock();
    error ReentrantCall();
    error ZeroAmount();
    error ClaimAccountingOverflow();
    error ClaimBalanceMismatch(uint256 required, uint256 actual);
    error AmountAboveAvailable(uint256 requested, uint256 available);
    error WithdrawalBatchTooLarge(uint256 requested, uint256 maximum);

    modifier nonReentrant() {
        if (reentrancyState != 1) revert ReentrantCall();
        reentrancyState = 2;
        _;
        reentrancyState = 1;
    }

    constructor(
        address kernel_,
        IPoolManager poolManager_,
        bytes32 poolId_,
        address quoteCurrency_,
        bool isBuy_,
        EcoBasketModuleVault vault_,
        bytes32 ecoConfigHash_
    ) {
        if (
            kernel_ == address(0) || kernel_.code.length == 0 || address(poolManager_) == address(0)
                || address(poolManager_).code.length == 0 || poolId_ == bytes32(0) || address(vault_) == address(0)
                || address(vault_).code.length == 0 || ecoConfigHash_ == bytes32(0)
        ) revert InvalidDependency();
        if (quoteCurrency_ != address(0) && quoteCurrency_.code.length == 0) revert InvalidDependency();

        kernel = kernel_;
        poolManager = poolManager_;
        poolId = poolId_;
        quoteCurrency = quoteCurrency_;
        isBuy = isBuy_;
        vault = address(vault_);
        ecoConfigHash = ecoConfigHash_;
    }

    function contractName() external pure returns (string memory) {
        return "EcoBasketClaimStrategyV1";
    }

    function contractVersion() external pure returns (string memory) {
        return "1.0.0";
    }

    function claimBalance() public view returns (uint256) {
        return poolManager.balanceOf(address(this), Currency.wrap(quoteCurrency).toId());
    }

    function accountingInvariant() external view returns (bool) {
        return cumulativeClaimsCredited == accountedClaims + cumulativeClaimsSettled;
    }

    function canCredit(uint256 amount) external view override returns (bool) {
        return amount != 0 && amount <= type(uint256).max - accountedClaims
            && amount <= type(uint256).max - cumulativeClaimsCredited;
    }

    /// @notice Accounts claims that the immutable Hookr kernel has already minted to this strategy.
    function creditClaims(uint256 amount) external override {
        if (msg.sender != kernel) revert NotKernel(msg.sender);
        if (amount == 0) revert ZeroAmount();
        if (amount > type(uint256).max - accountedClaims || amount > type(uint256).max - cumulativeClaimsCredited) {
            revert ClaimAccountingOverflow();
        }
        uint256 updated = accountedClaims + amount;
        uint256 actualClaims = claimBalance();
        if (actualClaims < updated) revert ClaimBalanceMismatch(updated, actualClaims);
        accountedClaims = updated;
        cumulativeClaimsCredited += amount;
        emit ClaimsCredited(poolId, isBuy, amount, updated);
    }

    /// @notice Permissionlessly settles backed quote claims to the immutable Eco vault.
    function settleClaims(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (amount > MAX_WITHDRAWAL_BATCH) revert WithdrawalBatchTooLarge(amount, MAX_WITHDRAWAL_BATCH);
        uint256 available = accountedClaims;
        if (amount > available) revert AmountAboveAvailable(amount, available);
        uint256 actualClaims = claimBalance();
        if (actualClaims < available) revert ClaimBalanceMismatch(available, actualClaims);

        accountedClaims = available - amount;
        cumulativeClaimsSettled += amount;
        withdrawingClaims = true;
        bytes memory result = poolManager.unlock(abi.encode(amount));
        withdrawingClaims = false;
        if (result.length != 32 || abi.decode(result, (uint256)) != amount) revert InvalidUnlock();

        EcoBasketModuleVault(payable(vault)).recordFee(quoteCurrency, amount, isBuy);
        emit ClaimsSettled(poolId, isBuy, vault, amount, available - amount);
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager(msg.sender);
        if (!withdrawingClaims) revert InvalidUnlock();
        uint256 amount = abi.decode(data, (uint256));
        Currency quote = Currency.wrap(quoteCurrency);
        poolManager.burn(address(this), quote.toId(), amount);
        poolManager.take(quote, vault, amount);
        return abi.encode(amount);
    }
}
