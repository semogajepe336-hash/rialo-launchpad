// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {LaunchpadErrors} from "./LaunchpadErrors.sol";

/// @title ConstantProductCurve
/// @notice Pure x*y=k swap math, Uniswap-v2 style. No storage, no external calls.
///
/// Naming convention is deliberately directional:
///   amountIn  goes INTO reserveIn , and amountOut comes OUT of reserveOut.
library ConstantProductCurve {
    /// @notice How much `reserveOut` you get for `amountIn` of `reserveIn`.
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        internal
        pure
        returns (uint256 amountOut)
    {
        if (amountIn == 0) revert LaunchpadErrors.ZeroAmount();
        if (reserveIn == 0 || reserveOut == 0) revert LaunchpadErrors.InsufficientLiquidity();

        uint256 newReserveIn = reserveIn + amountIn;
        uint256 newReserveOut = (reserveIn * reserveOut) / newReserveIn;
        amountOut = reserveOut - newReserveOut;
        if (amountOut == 0) revert LaunchpadErrors.InsufficientLiquidity();
    }

    /// @notice How much `reserveIn` you must pay to receive `amountOut` of `reserveOut`.
    function getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut)
        internal
        pure
        returns (uint256 amountIn)
    {
        if (amountOut == 0) revert LaunchpadErrors.ZeroAmount();
        if (reserveIn == 0 || reserveOut == 0 || amountOut >= reserveOut) {
            revert LaunchpadErrors.InsufficientLiquidity();
        }

        uint256 newReserveOut = reserveOut - amountOut;
        amountIn = ((reserveIn * reserveOut) / newReserveOut) - reserveIn;
        if (amountIn == 0) revert LaunchpadErrors.InsufficientLiquidity();
    }

    /// @notice Price (quote per token, scaled by 1e18) implied by the book.
    /// @param quoteReserve the quote side of the book
    /// @param tokenReserve the token side of the book
    function pricePerToken(uint256 quoteReserve, uint256 tokenReserve) internal pure returns (uint256) {
        if (tokenReserve == 0) return 0;
        return (quoteReserve * 1e18) / tokenReserve;
    }
}
