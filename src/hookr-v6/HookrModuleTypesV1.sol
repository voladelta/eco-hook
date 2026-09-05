// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice ABI-compatible subset of HookrModuleTypesV1 pinned by the V6 review source.
library HookrModuleTypesV1 {
    uint8 internal constant PHASE_BEFORE_ADD_LIQUIDITY = 1 << 0;
    uint8 internal constant PHASE_BEFORE_SWAP = 1 << 1;
    uint8 internal constant PHASE_AFTER_SWAP = 1 << 2;

    struct ModuleConfigCaps {
        bytes32 configHash;
        uint24 maxLpFeeSurchargePips;
        uint16 maxSpecifiedQuoteTakeBps;
        uint16 maxUnspecifiedQuoteTakeBps;
        uint16 maxSubjectTakeBps;
    }

    struct LiquidityContext {
        bytes32 poolId;
        address sender;
        address subject;
        address quote;
        int24 tickLower;
        int24 tickUpper;
        int256 liquidityDelta;
        bytes32 salt;
        bytes hookData;
    }

    struct SwapContext {
        bytes32 poolId;
        address sender;
        address payer;
        address recipient;
        address subject;
        address quote;
        bool trustedCaller;
        bool isBuy;
        bool exactInput;
        bool zeroForOne;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
        bytes hookData;
    }

    struct AfterSwapContext {
        bytes32 poolId;
        address sender;
        address payer;
        address recipient;
        address subject;
        address quote;
        bool trustedCaller;
        bool isBuy;
        bool exactInput;
        bool zeroForOne;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
        int128 amount0;
        int128 amount1;
        bytes hookData;
    }

    struct ModuleResult {
        uint24 lpFeeSurchargePips;
        uint16 quoteTakeBps;
        address claimRecipient;
        bytes32 attributionKey;
    }
}
