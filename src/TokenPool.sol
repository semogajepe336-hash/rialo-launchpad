// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "./interfaces/IERC20.sol";

/// @title TokenPool
/// @notice Constant-sum pool (`1 token0 == rate token1`) seeded by the launchpad at graduation.
///         The rate is fixed at creation from the final bonding-curve price, so the market is
///         continuous across the curve -> pool transition.
///
///         Security model: the pool never approves anyone and never pulls tokens. Swaps are
///         push-only: callers transfer the input in first, then the pool transfers the output out.
contract TokenPool {
    IERC20 public immutable token0; // project token (18d)
    IERC20 public immutable token1; // quote asset  (18d)
    /// @dev quote received per token spent, scaled by 1e18.
    uint256 public immutable rate;

    uint112 private reserve0;
    uint112 private reserve1;
    uint112 private totalLpShares;

    constructor(IERC20 _token0, IERC20 _token1, uint256 _rate) {
        if (address(_token0) == address(0) || address(_token1) == address(0) || _rate == 0) revert();
        token0 = _token0;
        token1 = _token1;
        rate = _rate;
    }

    function getReserves() external view returns (uint256 _reserve0, uint256 _reserve1) {
        (_reserve0, _reserve1) = (reserve0, reserve1);
    }

    function totalSupplyLp() external view returns (uint256) {
        return totalLpShares;
    }

    /// @notice Seeds the pool. Callable once, only by the creator, who must have approved both tokens.
    /// @return lpShares sqrt(reserve0 * reserve1), Uniswap-style.
    function initialize(uint112 amount0, uint112 amount1) external returns (uint256 lpShares) {
        if (totalLpShares != 0) revert();
        require(token0.transferFrom(msg.sender, address(this), amount0), "T0");
        require(token1.transferFrom(msg.sender, address(this), amount1), "T1");
        reserve0 = amount0;
        reserve1 = amount1;
        lpShares = _sqrt(uint256(amount0) * uint256(amount1));
        totalLpShares = uint112(lpShares);
    }

    /// @notice Sell `amount0In` token0 for token1 at the fixed rate.
    function swapExactToken0ForToken1(uint256 amount0In, uint256 amount1MinOut, address to)
        external
        returns (uint256 amount1Out)
    {
        if (amount0In == 0) revert();
        amount1Out = getAmount1Out(amount0In);
        if (amount1Out < amount1MinOut) revert();
        require(token0.transferFrom(msg.sender, address(this), amount0In), "T0");
        reserve0 += uint112(amount0In);
        if (uint256(reserve1) < amount1Out) revert();
        reserve1 -= uint112(amount1Out);
        require(token1.transfer(to, amount1Out), "T1");
    }

    /// @notice Sell `amount1In` token1 for token0 at the fixed rate.
    function swapExactToken1ForToken0(uint256 amount1In, uint256 amount0MinOut, address to)
        external
        returns (uint256 amount0Out)
    {
        if (amount1In == 0) revert();
        amount0Out = getAmount0Out(amount1In);
        if (amount0Out < amount0MinOut) revert();
        require(token1.transferFrom(msg.sender, address(this), amount1In), "T1");
        reserve1 += uint112(amount1In);
        if (uint256(reserve0) < amount0Out) revert();
        reserve0 -= uint112(amount0Out);
        require(token0.transfer(to, amount0Out), "T0");
    }

    function getAmount1Out(uint256 amount0In) public view returns (uint256) {
        return (amount0In * rate) / 1e18;
    }

    function getAmount0Out(uint256 amount1In) public view returns (uint256) {
        return (amount1In * 1e18) / rate;
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}
