// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title LaunchpadErrors
/// @notice All custom errors so revert strings stay cheap and call sites stay readable.
library LaunchpadErrors {
    error Unauthorized(); // 0x82b42900
    error Paused(); // 0x9e87fac8
    error InvalidToken(); // 0xa7f89e5a
    error InsufficientLiquidity();
    error InsufficientOutputAmount(); // 0x5454f7ba (v2-style)
    error ExcessiveInputAmount();
    error ZeroAmount();
    error ZeroAddress();
    error SlippageExceeded();
    error TransferFailed();
    error NotInCurvePhase();
    error NotInLivePhase();
    error AlreadyGraduated();
    error NotGraduated();
    error KShrunk();
    error InvalidConfig();
    error AlreadySet();
    error NoLiquidityAdded();
    error NotImplemented();
}
