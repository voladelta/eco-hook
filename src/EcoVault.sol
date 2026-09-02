// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";

import {NarrativeOrderHub} from "./NarrativeOrderHub.sol";

/// @notice Holds collected fees and isolated allocation accounting for one pool.
contract EcoVault {
    using CurrencyLibrary for Currency;

    enum MarketAllocation {
        Buyback,
        Liquidity
    }

    struct Allocation {
        uint256 basket;
        uint256 buyback;
        uint256 liquidity;
    }

    error OnlyHook(address caller);
    error OnlyExecutor(address caller);
    error OnlyOrderHub(address caller);
    error NoBasketBudget(address fundingToken);
    error InvalidReleaseAmount(uint256 requested, uint256 available);

    address public immutable hook;
    NarrativeOrderHub public immutable orderHub;
    address public immutable approvedExecutor;
    PoolId public immutable poolId;
    address public immutable strategyToken;
    uint32 public immutable orderInterval;
    uint8 public immutable orderSteps;

    address[] private _basketTokens;
    mapping(address fundingToken => Allocation allocation) public allocations;
    mapping(address fundingToken => uint256 amount) public scheduledBasket;

    event FeeAllocated(address indexed fundingToken, bool indexed buy, uint256 amount);
    event BasketOrdersScheduled(address indexed fundingToken, uint256 amount, uint256 startAt);
    event MarketFundsReleased(
        address indexed fundingToken, MarketAllocation indexed allocation, address indexed executor, uint256 amount
    );
    event OrderFundsReleased(address indexed fundingToken, address indexed executor, uint256 amount);
    event OrderFundsRestored(address indexed fundingToken, uint256 amount);

    constructor(
        address hook_,
        address orderHub_,
        address approvedExecutor_,
        PoolId poolId_,
        address strategyToken_,
        address[] memory basketTokens_,
        uint32 orderInterval_,
        uint8 orderSteps_
    ) {
        hook = hook_;
        orderHub = NarrativeOrderHub(orderHub_);
        approvedExecutor = approvedExecutor_;
        poolId = poolId_;
        strategyToken = strategyToken_;
        orderInterval = orderInterval_;
        orderSteps = orderSteps_;
        _basketTokens = basketTokens_;
    }

    receive() external payable {}

    function basketTokens() external view returns (address[] memory) {
        return _basketTokens;
    }

    /// @notice Records allocation only. It never swaps or adds liquidity.
    function recordFee(address fundingToken, uint256 amount, bool buy) external {
        if (msg.sender != hook) revert OnlyHook(msg.sender);
        Allocation storage allocation = allocations[fundingToken];
        if (buy) {
            uint256 basketAmount = amount * 80 / 100;
            uint256 buybackAmount = amount * 10 / 100;
            allocation.basket += basketAmount;
            allocation.buyback += buybackAmount;
            allocation.liquidity += amount - basketAmount - buybackAmount;
        } else {
            uint256 buybackAmount = amount * 50 / 100;
            allocation.buyback += buybackAmount;
            allocation.liquidity += amount - buybackAmount;
        }
        emit FeeAllocated(fundingToken, buy, amount);
    }

    /// @notice Converts all current basket budget into deterministic orders that start in this block.
    function scheduleBasketOrders(address fundingToken) external returns (uint256 firstOrderId) {
        if (msg.sender != approvedExecutor) revert OnlyExecutor(msg.sender);
        uint256 budget = allocations[fundingToken].basket;
        if (budget == 0) revert NoBasketBudget(fundingToken);
        allocations[fundingToken].basket = 0;
        scheduledBasket[fundingToken] += budget;

        uint256 count = _basketTokens.length;
        uint256 share = budget / count;
        firstOrderId = orderHub.nextOrderId();
        for (uint256 i; i < count; ++i) {
            uint256 amount = i + 1 == count ? budget - share * i : share;
            orderHub.createOrder(poolId, fundingToken, _basketTokens[i], amount, orderInterval, orderSteps);
        }
        emit BasketOrdersScheduled(fundingToken, budget, block.timestamp);
    }

    /// @notice Releases only recorded buyback or liquidity funds to the immutable executor.
    function releaseMarketFunds(address fundingToken, MarketAllocation marketAllocation, uint256 amount) external {
        if (msg.sender != approvedExecutor) revert OnlyExecutor(msg.sender);
        Allocation storage allocation = allocations[fundingToken];
        uint256 available = marketAllocation == MarketAllocation.Buyback ? allocation.buyback : allocation.liquidity;
        if (amount == 0 || amount > available) revert InvalidReleaseAmount(amount, available);
        if (marketAllocation == MarketAllocation.Buyback) allocation.buyback = available - amount;
        else allocation.liquidity = available - amount;
        Currency.wrap(fundingToken).transfer(approvedExecutor, amount);
        emit MarketFundsReleased(fundingToken, marketAllocation, approvedExecutor, amount);
    }

    /// @notice Called after the order hub advances due accounting.
    function releaseOrderFunds(address fundingToken, uint256 amount) external {
        if (msg.sender != address(orderHub)) revert OnlyOrderHub(msg.sender);
        uint256 available = scheduledBasket[fundingToken];
        if (amount == 0 || amount > available) revert InvalidReleaseAmount(amount, available);
        scheduledBasket[fundingToken] = available - amount;
        Currency.wrap(fundingToken).transfer(approvedExecutor, amount);
        emit OrderFundsReleased(fundingToken, approvedExecutor, amount);
    }

    /// @notice Returns expired, unreleased order accounting to the basket allocation.
    function restoreOrderFunds(address fundingToken, uint256 amount) external {
        if (msg.sender != address(orderHub)) revert OnlyOrderHub(msg.sender);
        uint256 available = scheduledBasket[fundingToken];
        if (amount == 0 || amount > available) revert InvalidReleaseAmount(amount, available);
        scheduledBasket[fundingToken] = available - amount;
        allocations[fundingToken].basket += amount;
        emit OrderFundsRestored(fundingToken, amount);
    }
}
