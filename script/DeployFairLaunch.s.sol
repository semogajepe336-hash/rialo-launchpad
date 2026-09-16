// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {FairLaunch} from "../src/FairLaunch.sol";
import {TokenPool} from "../src/TokenPool.sol";
import {MockToken} from "../src/mocks/MockToken.sol";

/// @title DeployFairLaunch
/// @notice Deploys the full fair launch stack to Sepolia and logs every address.
///         Uses a MockToken as the quote asset so the whole thing is self-contained
///         for the testnet. On a real chain you would pass an existing WETH address.
contract DeployFairLaunch is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);

        MockToken token = new MockToken("Rialo", "RLO");
        MockToken quote = new MockToken("Wrapped Sepolia ETH", "WSETH");

        // project supply minted straight to the launchpad, as the design requires
        FairLaunch launch = new FairLaunch(token, quote, 100 ether);
        token.mint(address(launch), 1_000_000 ether);

        // airdrop some quote to a few test addresses so people can try buying
        address[3] memory testers = [
            address(0xA11CE),
            address(0xA1),
            address(0xB0B)
        ];
        for (uint256 i = 0; i < testers.length; i++) {
            quote.mint(testers[i], 1000 ether);
        }

        vm.stopBroadcast();

        console.log("=== deployed ===");
        console.log("TOKEN");
        console.logAddress(address(token));
        console.log("QUOTE");
        console.logAddress(address(quote));
        console.log("FAIRLAUNCH");
        console.logAddress(address(launch));
        console.log("TARGET");
        console.logUint(100 ether);
    }
}
