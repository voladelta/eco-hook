// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

interface IEcoVaultRegistry {
    function isVault(address vault) external view returns (bool);
}

interface IEcoOrderVault {
    function releaseOrderFunds(address fundingToken, uint256 amount) external;
    function restoreOrderFunds(address fundingToken, uint256 amount) external;
}

/// @notice Releases bounded scheduled accounting through registered vaults. It never calls a pool or router.
contract NarrativeOrderHub {
    enum Status {
        None,
        Active,
        Complete,
        Expired
    }

    struct Order {
        PoolId poolId;
        address vault;
        address fundingToken;
        address targetToken;
        uint128 totalAmount;
        uint128 releasedAmount;
        uint64 startAt;
        uint32 interval;
        uint8 totalSteps;
        uint8 releasedSteps;
        Status status;
    }

    error OnlyRegisteredVault(address caller);
    error OnlyExecutor(address caller);
    error InvalidOrder();
    error OrderNotActive(uint256 orderId);
    error InvalidStepLimit(uint256 maxSteps);
    error OrderNotExpired(uint256 orderId);
    error OrderPastExpiry(uint256 orderId);

    uint8 public constant MAX_STEPS_PER_CALL = 8;
    uint256 public constant EXPIRY_GRACE = 30 days;

    IEcoVaultRegistry public immutable registry;
    address public immutable approvedExecutor;
    uint256 public nextOrderId = 1;
    mapping(uint256 orderId => Order order) public orders;

    event OrderCreated(uint256 indexed orderId, PoolId indexed poolId, address indexed targetToken, uint256 amount);
    event OrderReleased(uint256 indexed orderId, uint256 amount, uint8 steps);
    event OrderExpired(uint256 indexed orderId, uint256 cancelledAmount);

    constructor(address registry_, address approvedExecutor_) {
        registry = IEcoVaultRegistry(registry_);
        approvedExecutor = approvedExecutor_;
    }

    function createOrder(
        PoolId poolId,
        address fundingToken,
        address targetToken,
        uint256 amount,
        uint32 interval,
        uint8 totalSteps
    ) external returns (uint256 orderId) {
        if (!registry.isVault(msg.sender)) revert OnlyRegisteredVault(msg.sender);
        if (
            targetToken == address(0) || amount == 0 || amount > type(uint128).max || block.timestamp > type(uint64).max
                || interval == 0 || totalSteps == 0
        ) revert InvalidOrder();
        orderId = nextOrderId++;
        orders[orderId] = Order({
            poolId: poolId,
            vault: msg.sender,
            fundingToken: fundingToken,
            targetToken: targetToken,
            totalAmount: uint128(amount),
            releasedAmount: 0,
            startAt: uint64(block.timestamp),
            interval: interval,
            totalSteps: totalSteps,
            releasedSteps: 0,
            status: Status.Active
        });
        emit OrderCreated(orderId, poolId, targetToken, amount);
    }

    /// @notice Advances at most eight due steps before the vault pays the immutable executor.
    function releaseDue(uint256 orderId, uint8 maxSteps) external returns (uint256 released) {
        if (msg.sender != approvedExecutor) revert OnlyExecutor(msg.sender);
        if (maxSteps == 0 || maxSteps > MAX_STEPS_PER_CALL) revert InvalidStepLimit(maxSteps);
        Order storage order = orders[orderId];
        if (order.status != Status.Active) revert OrderNotActive(orderId);
        if (block.timestamp < order.startAt) return 0;
        uint256 expiry = uint256(order.startAt) + uint256(order.interval) * order.totalSteps + EXPIRY_GRACE;
        if (block.timestamp > expiry) revert OrderPastExpiry(orderId);

        uint256 due = (block.timestamp - order.startAt) / order.interval + 1;
        if (due > order.totalSteps) due = order.totalSteps;
        uint256 availableSteps = due - order.releasedSteps;
        uint256 steps = availableSteps > maxSteps ? maxSteps : availableSteps;
        if (steps == 0) return 0;

        uint256 newStepCount = order.releasedSteps + steps;
        uint256 newReleased = uint256(order.totalAmount) * newStepCount / order.totalSteps;
        released = newReleased - order.releasedAmount;
        order.releasedSteps = uint8(newStepCount);
        order.releasedAmount = uint128(newReleased);
        if (newStepCount == order.totalSteps) order.status = Status.Complete;
        IEcoOrderVault(order.vault).releaseOrderFunds(order.fundingToken, released);
        emit OrderReleased(orderId, released, uint8(steps));
    }

    function expire(uint256 orderId) external returns (uint256 cancelledAmount) {
        Order storage order = orders[orderId];
        if (order.status != Status.Active) revert OrderNotActive(orderId);
        uint256 expiry = uint256(order.startAt) + uint256(order.interval) * order.totalSteps + EXPIRY_GRACE;
        if (block.timestamp <= expiry) revert OrderNotExpired(orderId);
        cancelledAmount = order.totalAmount - order.releasedAmount;
        order.status = Status.Expired;
        IEcoOrderVault(order.vault).restoreOrderFunds(order.fundingToken, cancelledAmount);
        emit OrderExpired(orderId, cancelledAmount);
    }
}
