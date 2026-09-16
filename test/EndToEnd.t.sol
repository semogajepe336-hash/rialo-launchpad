// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {FairLaunch} from "../src/FairLaunch.sol";
import {TokenPool} from "../src/TokenPool.sol";
import {MockToken} from "../src/mocks/MockToken.sol";

/// @title EndToEndTest
/// @notice Full lifecycle exactly as a user would walk it, including the approve step.
contract EndToEndTest is Test {
    MockToken token;
    MockToken quote;
    FairLaunch launch;

    address owner = address(0xA11CE);
    address user = address(0xCAFE);

    uint256 constant TARGET = 100 ether;
    uint256 constant MINT = 1_000_000 ether;
    uint256 constant SEED = 10 ether;

    function setUp() public {
        vm.startPrank(owner);
        token = new MockToken("Rialo", "RLO");
        quote = new MockToken("Wrapped Sepolia ETH", "WSETH");
        launch = new FairLaunch(token, quote, TARGET);
        token.mint(address(launch), MINT);
        quote.mint(owner, 1000 ether);
        quote.mint(user, 500 ether);
        quote.approve(address(launch), type(uint256).max);
        launch.seed(SEED);
        vm.stopPrank();
    }

    function test_FullLifecycle() public {
        // 1. user buys across many trades
        uint256 totalIn = 0;
        for (uint256 i = 0; i < 12; i++) {
            uint256 amt = 5 ether + (i * 0.5 ether);
            vm.startPrank(user);
            quote.approve(address(launch), amt);
            uint256 out = launch.buy(amt, 0, user);
            assertGt(out, 0, "buy must return tokens");
            totalIn += amt;
            vm.stopPrank();
            if (uint8(launch.phase()) == uint8(FairLaunch.Phase.Live)) break;
        }

        // 2. graduation happened
        assertEq(uint8(launch.phase()), uint8(FairLaunch.Phase.Live), "must graduate");
        TokenPool pool = TokenPool(launch.pool());

        // 3. fees claimable by owner
        uint256 fees = launch.feesAccrued();
        assertGt(fees, 0);
        uint256 ownerBefore = quote.balanceOf(owner);
        vm.prank(owner);
        launch.withdrawFees(owner);
        assertEq(quote.balanceOf(owner) - ownerBefore, fees);

        // 4. the whole book moved into the pool
        (uint256 p0, uint256 p1) = pool.getReserves();
        assertGt(p0, 0);
        assertGt(p1, 0);

        // 5. user trades in the pool
        vm.startPrank(user);
        quote.approve(address(pool), type(uint256).max);
        uint256 tokens = pool.swapExactToken1ForToken0(2 ether, 0, user);
        assertGt(tokens, 0);
        token.approve(address(pool), type(uint256).max);
        uint256 back = pool.swapExactToken0ForToken1(tokens, 0, user);
        assertLe(back, 2 ether, "round trip must not profit");
        vm.stopPrank();
    }

    function test_SandwichResistance() public {
        // attacker buys big to push price, victim buys, attacker sells -> victim must still be fine
        address attacker = address(0xBAD);
        quote.mint(attacker, 500 ether);

        uint256 victimStart = quote.balanceOf(user);

        vm.startPrank(attacker);
        quote.approve(address(launch), type(uint256).max);
        token.approve(address(launch), type(uint256).max);
        uint256 atkOut = launch.buy(50 ether, 0, attacker);
        vm.stopPrank();

        uint256 priceAfterPump = launch.price();

        vm.startPrank(user);
        quote.approve(address(launch), 5 ether);
        uint256 victimOut = launch.buy(5 ether, 0, user);
        vm.stopPrank();

        vm.startPrank(attacker);
        launch.sell(atkOut, 0, attacker);
        vm.stopPrank();

        // victim bought against a small book at a low absolute price, so they get more tokens
        // than quote spent in absolute terms, but strictly less than a pro-rata 1:1 slice
        assertGt(victimOut, 0);
        assertLt(victimOut, (5 ether * token.balanceOf(address(launch))) / quote.balanceOf(address(launch)));
        assertLe(quote.balanceOf(user), victimStart - 5 ether);

        // price recovered after the attacker unwound
        assertLt(launch.price(), priceAfterPump);
    }

    function test_NoFreeMoney() public {
        // the classic: buy -> sell -> buy -> sell ... must monotonically drain the caller
        uint256 startQuote = quote.balanceOf(user);
        uint256 startToken = token.balanceOf(user);
        assertEq(startToken, 0);

        vm.startPrank(user);
        quote.approve(address(launch), type(uint256).max);
        token.approve(address(launch), type(uint256).max);
        for (uint256 i = 0; i < 20; i++) {
            uint256 q0 = quote.balanceOf(user);
            uint256 out = launch.buy(1 ether, 0, user);
            if (uint8(launch.phase()) != uint8(FairLaunch.Phase.Curve)) break;
            launch.sell(out, 0, user);
            assertLt(quote.balanceOf(user), q0, "each cycle must cost the user");
        }
        vm.stopPrank();
        assertLt(quote.balanceOf(user), startQuote, "user must end with less quote");
    }
}
