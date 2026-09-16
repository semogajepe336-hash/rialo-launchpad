// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Burnable extension the project token must implement so the launchpad can
///         remove sold tokens from circulation on the bonding curve.
interface IBurnable {
    function burn(uint256 amount) external;
    function burnFrom(address from, uint256 amount) external;
}
