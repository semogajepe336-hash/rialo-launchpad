// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal ERC20 interface for the curve token + paired asset (WETH/ETH test token).
interface IERC20 {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
}

/// @notice Constant-sum pool used for the internal liquidity book of the launchpad.
///         One-sided deposits only (the launchpad always owns 100% of the pool).
interface IPool {
    function addLiquidity(uint256 amount0, uint256 amount1) external;
    function swapExactToken0ForToken1(uint256 amount0In, uint256 amount1MinOut, address to) external returns (uint256);
    function swapExactToken1ForToken0(uint256 amount1In, uint256 amount0MinOut, address to) external returns (uint256);
    function getReserves() external view returns (uint256 reserve0, uint256 reserve1);
    function token0() external view returns (address);
    function token1() external view returns (address);
}
