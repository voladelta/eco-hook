// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";

import {NarrativeOrderHub} from "./NarrativeOrderHub.sol";

/// @notice Isolated Eco allocation vault funded by two direction-bound Hookr claim strategies.
contract EcoBasketModuleVault {
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

    error OnlyRegistry(address caller);
    error SourcesAlreadyActivated();
    error InvalidSource(address caller, bool buy);
    error InvalidFundingToken(address token);
    error InvalidDependency();
    error OnlyExecutor(address caller);
    error OnlyOrderHub(address caller);
    error NoBasketBudget(address fundingToken);
    error InvalidReleaseAmount(uint256 requested, uint256 available);

    address public immutable registry;
    NarrativeOrderHub public immutable orderHub;
    address public immutable approvedExecutor;
    PoolId public immutable poolId;
    address public immutable strategyToken;
    address public immutable quoteCurrency;
    uint32 public immutable orderInterval;
    uint8 public immutable orderSteps;
    bytes32 public immutable ecoConfigHash;

    address public buyStrategy;
    address public sellStrategy;
    address[] private _basketTokens;
    mapping(address fundingToken => Allocation allocation) public allocations;
    mapping(address fundingToken => uint256 amount) public scheduledBasket;

    uint8 private buyBasketRemainder;
    uint8 private buyMarketRemainder;
    uint8 private sellMarketRemainder;

    event SourcesActivated(address indexed buyStrategy, address indexed sellStrategy);
    event FeeAllocated(address indexed fundingToken, bool indexed buy, uint256 amount);
    event BasketOrdersScheduled(address indexed fundingToken, uint256 amount, uint256 startAt);
    event MarketFundsReleased(
        address indexed fundingToken, MarketAllocation indexed allocation, address indexed executor, uint256 amount
    );
    event OrderFundsReleased(address indexed fundingToken, address indexed executor, uint256 amount);
    event OrderFundsRestored(address indexed fundingToken, uint256 amount);

    constructor(
        address registry_,
        address orderHub_,
        address approvedExecutor_,
        PoolId poolId_,
        address strategyToken_,
        address quoteCurrency_,
        address[] memory basketTokens_,
        uint32 orderInterval_,
        uint8 orderSteps_,
        bytes32 ecoConfigHash_
    ) {
        if (
            registry_ == address(0) || orderHub_ == address(0) || approvedExecutor_ == address(0)
                || PoolId.unwrap(poolId_) == bytes32(0) || strategyToken_ == address(0) || basketTokens_.length == 0
                || orderInterval_ == 0 || orderSteps_ == 0 || ecoConfigHash_ == bytes32(0)
        ) revert InvalidDependency();
        registry = registry_;
        orderHub = NarrativeOrderHub(orderHub_);
        approvedExecutor = approvedExecutor_;
        poolId = poolId_;
        strategyToken = strategyToken_;
        quoteCurrency = quoteCurrency_;
        orderInterval = orderInterval_;
        orderSteps = orderSteps_;
        ecoConfigHash = ecoConfigHash_;
        _basketTokens = basketTokens_;
    }

    receive() external payable {}

    function basketTokens() external view returns (address[] memory) {
        return _basketTokens;
    }

    function activateSources(address buyStrategy_, address sellStrategy_) external {
        if (msg.sender != registry) revert OnlyRegistry(msg.sender);
        if (buyStrategy != address(0) || sellStrategy != address(0)) revert SourcesAlreadyActivated();
        if (buyStrategy_ == address(0)) revert InvalidSource(address(0), true);
        buyStrategy = buyStrategy_;
        sellStrategy = sellStrategy_;
        emit SourcesActivated(buyStrategy_, sellStrategy_);
    }

    function recordFee(address fundingToken, uint256 amount, bool buy) external {
        if (fundingToken != quoteCurrency) revert InvalidFundingToken(fundingToken);
        address expected = buy ? buyStrategy : sellStrategy;
        if (expected == address(0) || msg.sender != expected) revert InvalidSource(msg.sender, buy);

        Allocation storage allocation = allocations[fundingToken];
        if (buy) {
            // Carry fractions independently of released budgets. Split the non-basket units
            // equally so no settlement ever allocates more units than it receives.
            uint256 basketNumerator = amount * 8 + buyBasketRemainder;
            uint256 basketAmount = basketNumerator / 10;
            buyBasketRemainder = uint8(basketNumerator % 10);
            uint256 marketNumerator = amount - basketAmount + buyMarketRemainder;
            uint256 buybackAmount = marketNumerator / 2;
            buyMarketRemainder = uint8(marketNumerator % 2);
            allocation.basket += basketAmount;
            allocation.buyback += buybackAmount;
            allocation.liquidity += amount - basketAmount - buybackAmount;
        } else {
            uint256 marketNumerator = amount + sellMarketRemainder;
            uint256 buybackAmount = marketNumerator / 2;
            sellMarketRemainder = uint8(marketNumerator % 2);
            allocation.buyback += buybackAmount;
            allocation.liquidity += amount - buybackAmount;
        }
        emit FeeAllocated(fundingToken, buy, amount);
    }

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

    function releaseOrderFunds(address fundingToken, uint256 amount) external {
        if (msg.sender != address(orderHub)) revert OnlyOrderHub(msg.sender);
        // Let the pinned order hub advance dust steps without making a zero-value transfer.
        if (amount == 0) return;
        uint256 available = scheduledBasket[fundingToken];
        if (amount > available) revert InvalidReleaseAmount(amount, available);
        scheduledBasket[fundingToken] = available - amount;
        Currency.wrap(fundingToken).transfer(approvedExecutor, amount);
        emit OrderFundsReleased(fundingToken, approvedExecutor, amount);
    }

    function restoreOrderFunds(address fundingToken, uint256 amount) external {
        if (msg.sender != address(orderHub)) revert OnlyOrderHub(msg.sender);
        uint256 available = scheduledBasket[fundingToken];
        if (amount == 0 || amount > available) revert InvalidReleaseAmount(amount, available);
        scheduledBasket[fundingToken] = available - amount;
        allocations[fundingToken].basket += amount;
        emit OrderFundsRestored(fundingToken, amount);
    }
}
