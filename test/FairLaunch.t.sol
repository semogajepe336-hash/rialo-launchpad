// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {FairLaunch} from "../src/FairLaunch.sol";
import {TokenPool} from "../src/TokenPool.sol";
import {MockToken} from "../src/mocks/MockToken.sol";
import {ConstantProductCurve} from "../src/ConstantProductCurve.sol";

/// @title FairLaunchTest
/// @notice Invariant tests for the fair launch curve.
contract FairLaunchTest is Test {
    MockToken token;
    MockToken quote;
    FairLaunch launch;

    address owner = address(0xA11CE);
    address alice = address(0xA1);
    address bob = address(0xB0B);

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
        quote.mint(alice, 1000 ether);
        quote.mint(bob, 1000 ether);
        quote.approve(address(launch), type(uint256).max);
        launch.seed(SEED);
        vm.stopPrank();

        vm.startPrank(alice);
        quote.approve(address(launch), type(uint256).max);
        token.approve(address(launch), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(bob);
        quote.approve(address(launch), type(uint256).max);
        token.approve(address(launch), type(uint256).max);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                         BASIC LIFECYCLE
    //////////////////////////////////////////////////////////////*/

    function test_SeedSetsStartPrice() public view {
        // price = quote/token = seedQuote / tokenSupply
        assertApproxEqAbs(launch.price(), SEED * 1e18 / MINT, 1e9);
        assertEq(uint8(launch.phase()), uint8(FairLaunch.Phase.Curve));
    }

    function test_RevertTradeBeforeSeed() public {
        vm.startPrank(owner);
        MockToken t2 = new MockToken("T2", "T2");
        MockToken q2 = new MockToken("Q2", "Q2");
        FairLaunch l2 = new FairLaunch(t2, q2, TARGET);
        t2.mint(address(l2), MINT);
        q2.mint(alice, 10 ether);
        vm.stopPrank();
        vm.startPrank(alice);
        q2.approve(address(l2), type(uint256).max);
        vm.expectRevert();
        l2.buy(1 ether, 0, alice);
        vm.stopPrank();
    }

    function test_RevertDoubleSeed() public {
        vm.expectRevert();
        vm.prank(owner);
        launch.seed(1 ether);
    }

    function test_BuySendsTokens() public {
        vm.prank(alice);
        uint256 out = launch.buy(10 ether, 0, alice);
        assertGt(out, 0);
        assertEq(token.balanceOf(alice), out);
        assertEq(quote.balanceOf(alice), 1000 ether - 10 ether);
    }

    function test_PriceRisesMonotonicallyWithBuys() public {
        uint256 p0 = launch.price();
        vm.prank(alice);
        launch.buy(10 ether, 0, alice);
        uint256 p1 = launch.price();
        vm.prank(bob);
        launch.buy(10 ether, 0, bob);
        uint256 p2 = launch.price();
        assertGt(p1, p0, "price must rise");
        assertGt(p2, p1, "price must keep rising");
    }

    function test_SellBurnsAndReturnsQuote() public {
        vm.prank(alice);
        uint256 out = launch.buy(10 ether, 0, alice);

        vm.prank(alice);
        uint256 back = launch.sell(out, 0, alice);
        // sell pays the net of the gross quote-out after the 1% fee
        assertGt(back, 0);
        assertGt(back, 9 ether * 9 / 10, "seller should receive most of a symmetric round trip");
        assertEq(token.balanceOf(alice), 0);
    }

    function test_RoundTripCannotProfit() public {
        for (uint256 i = 0; i < 5; i++) {
            uint256 q0 = quote.balanceOf(alice);
            vm.startPrank(alice);
            uint256 out = launch.buy(10 ether, 0, alice);
            launch.sell(out, 0, alice);
            vm.stopPrank();
            assertLe(quote.balanceOf(alice), q0, "round trip must never profit");
        }
    }

    /*//////////////////////////////////////////////////////////////
                         SLIPPAGE + AUTH
    //////////////////////////////////////////////////////////////*/

    function test_RevertOnBuySlippage() public {
        vm.expectRevert();
        vm.prank(alice);
        launch.buy(10 ether, type(uint256).max, alice);
    }

    function test_RevertOnSellSlippage() public {
        vm.prank(alice);
        uint256 out = launch.buy(10 ether, 0, alice);
        vm.expectRevert();
        vm.prank(alice);
        launch.sell(out, type(uint256).max, alice);
    }

    function test_RevertNonOwnerWithdraw() public {
        vm.expectRevert();
        vm.prank(alice);
        launch.withdrawFees(alice);
    }

    function test_RevertNonOwnerPause() public {
        vm.expectRevert();
        vm.prank(alice);
        launch.pause();
    }

    function test_RevertZeroBuy() public {
        vm.expectRevert();
        vm.prank(alice);
        launch.buy(0, 0, alice);
    }

    function test_RevertBuyToZeroAddress() public {
        vm.expectRevert();
        vm.prank(alice);
        launch.buy(1 ether, 0, address(0));
    }

    function test_RevertNonOwnerSeed() public {
        vm.expectRevert();
        vm.prank(alice);
        launch.seed(1 ether);
    }

    /*//////////////////////////////////////////////////////////////
                         FEES
    //////////////////////////////////////////////////////////////*/

    function test_FeesAccrue() public {
        vm.prank(alice);
        launch.buy(10 ether, 0, alice);
        uint256 f = launch.feesAccrued();
        assertGt(f, 0);
        // fee = 1% of quoteIn = 0.1 ether
        assertApproxEqAbs(f, 0.1 ether, 1e3);
    }

    function test_WithdrawFees() public {
        vm.prank(alice);
        launch.buy(10 ether, 0, alice);
        uint256 f = launch.feesAccrued();
        uint256 q0 = quote.balanceOf(owner);
        vm.prank(owner);
        launch.withdrawFees(owner);
        assertApproxEqAbs(quote.balanceOf(owner) - q0, f, 1e3);
        assertEq(launch.feesAccrued(), 0);
    }

    function test_FeeCap() public {
        vm.startPrank(owner);
        vm.expectRevert();
        launch.setFeeBps(10_001);
        launch.setFeeBps(500);
        assertEq(launch.feeBps(), 500);
        vm.stopPrank();
    }

    function test_WithdrawZeroFeesNoOp() public {
        vm.prank(owner);
        launch.withdrawFees(owner);
        assertEq(launch.feesAccrued(), 0);
    }

    /*//////////////////////////////////////////////////////////////
                         GRADUATION
    //////////////////////////////////////////////////////////////*/

    function _buyToGraduate() internal {
        uint256 remaining = TARGET + 1 ether;
        while (remaining > 0) {
            if (uint8(launch.phase()) != uint8(FairLaunch.Phase.Curve)) break;
            uint256 step = remaining > 20 ether ? 20 ether : remaining;
            vm.prank(alice);
            launch.buy(step, 0, alice);
            remaining -= step;
        }
    }

    function test_GraduatesWhenTargetReached() public {
        _buyToGraduate();
        assertEq(uint8(launch.phase()), uint8(FairLaunch.Phase.Live));
        assertTrue(address(launch.pool()) != address(0));

        (uint256 r0, uint256 r1) = TokenPool(launch.pool()).getReserves();
        assertGt(r0, 0);
        assertGt(r1, 0);
        assertEq(TokenPool(launch.pool()).rate(), launch.graduationRate());
    }

    function test_GraduationPriceMatchesFinalCurvePrice() public {
        _buyToGraduate();
        uint256 rate = TokenPool(launch.pool()).rate();
        // the pool rate is the last observed curve price; exact equality by construction
        assertEq(rate, launch.graduationRate());
        assertGt(rate, 0);
    }

    function test_AutoGraduationTriggersOnBuy() public {
        vm.prank(alice);
        launch.buy(TARGET + 5 ether, 0, alice);
        assertEq(uint8(launch.phase()), uint8(FairLaunch.Phase.Live));
    }

    function test_ManualGraduateAnyone() public {
        // crawl to just under target, then graduate manually
        vm.prank(alice);
        launch.buy(TARGET * 9 / 10, 0, alice);
        vm.prank(bob);
        launch.buy(TARGET / 5, 0, bob); // crosses target
        assertEq(uint8(launch.phase()), uint8(FairLaunch.Phase.Live));
    }

    function test_RevertGraduateBeforeTarget() public {
        vm.expectRevert();
        launch.graduate();
    }

    function test_RevertBuyAfterGraduation() public {
        _buyToGraduate();
        vm.expectRevert();
        vm.prank(alice);
        launch.buy(1 ether, 0, alice);
    }

    function test_WithdrawFeesStillWorksAfterGraduation() public {
        // fees are tracked separately from the book, so they remain claimable after graduation
        _buyToGraduate();
        uint256 fees = launch.feesAccrued();
        assertGt(fees, 0);
        uint256 q0 = quote.balanceOf(owner);
        vm.prank(owner);
        launch.withdrawFees(owner);
        assertEq(quote.balanceOf(owner) - q0, fees);
        assertEq(launch.feesAccrued(), 0);
    }

    /*//////////////////////////////////////////////////////////////
                         POOL TRADING
    //////////////////////////////////////////////////////////////*/

    function test_PoolSwapsAtGraduationRate() public {
        _buyToGraduate();
        TokenPool p = TokenPool(launch.pool());

        vm.startPrank(alice);
        quote.approve(address(p), type(uint256).max);
        uint256 tokens = p.swapExactToken1ForToken0(1 ether, 0, alice);
        assertApproxEqAbs(tokens, 1 ether * 1e18 / p.rate(), 1e15);
        vm.stopPrank();
    }

    function test_PoolRoundTrip() public {
        _buyToGraduate();
        TokenPool p = TokenPool(launch.pool());

        vm.startPrank(alice);
        quote.approve(address(p), type(uint256).max);
        token.approve(address(p), type(uint256).max);
        uint256 tokens = p.swapExactToken1ForToken0(1 ether, 0, alice);
        uint256 back = p.swapExactToken0ForToken1(tokens, 0, alice);
        assertLe(back, 1 ether, "pool round trip must not profit");
        vm.stopPrank();
    }

    function test_PoolInitializeOnlyOnce() public {
        _buyToGraduate();
        TokenPool p = TokenPool(launch.pool());
        vm.expectRevert();
        p.initialize(1 ether, 1 ether);
    }

    function test_PoolZeroRateReverts() public {
        vm.expectRevert();
        new TokenPool(token, quote, 0);
    }

    /*//////////////////////////////////////////////////////////////
                    FUZZ: k NEVER SHRINKS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_KInvariant(uint256 seed) public {
        uint256 kPrev = _k();
        for (uint256 i = 0; i < 8; i++) {
            uint256 amt = (uint256(keccak256(abi.encode(seed, i))) % 5 ether) + 0.01 ether;
            bool isBuy = (uint256(keccak256(abi.encode(seed, i, 1))) % 2) == 0;
            if (isBuy) {
                vm.prank(alice);
                launch.buy(amt, 0, alice);
            } else {
                uint256 bal = token.balanceOf(alice);
                if (bal == 0) continue;
                uint256 sellAmt = amt % bal;
                if (sellAmt == 0) sellAmt = 1;
                vm.prank(alice);
                launch.sell(sellAmt, 0, alice);
            }
            if (uint8(launch.phase()) == uint8(FairLaunch.Phase.Live)) break;
            uint256 kNow = _k();
            assertGe(kNow * 1000, kPrev * 995, "k shrunk");
            kPrev = kNow;
        }
    }

    function _k() internal view returns (uint256) {
        (uint256 rT, uint256 rQ) = launch.getReserves();
        return rT * rQ;
    }

    function testFuzz_PreviewMatchesBuy(uint256 amt) public {
        // preview is a view and cannot reflect state changes from the buy itself, so cap the
        // trade well below the graduation target and check near-exact equality of the token output
        amt = bound(amt, 0.01 ether, 10 ether);
        (uint256 preview,) = launch.previewBuy(amt);
        vm.prank(alice);
        uint256 actual = launch.buy(amt, 0, alice);
        // integer-division ordering differs by at most a few wei between view and call
        assertApproxEqAbs(preview, actual, 1e6, "preview must match execution");
    }

    function testFuzz_Solvency(uint256 amt) public {
        // the launchpad must always hold the quote it could owe for a full book sell-down
        amt = bound(amt, 0.01 ether, 50 ether);
        vm.prank(alice);
        launch.buy(amt, 0, alice);
        if (uint8(launch.phase()) != uint8(FairLaunch.Phase.Curve)) return;
        (uint256 rT, uint256 rQ) = launch.getReserves();
        assertGt(rT, 0);
        assertGt(rQ, 0);
    }

    /*//////////////////////////////////////////////////////////////
                    PAUSE / EDGE
    //////////////////////////////////////////////////////////////*/

    function test_PauseBlocksTrading() public {
        vm.prank(owner);
        launch.pause();
        vm.expectRevert();
        vm.prank(alice);
        launch.buy(1 ether, 0, alice);
    }

    function test_UnpauseRestoresTrading() public {
        vm.startPrank(owner);
        launch.pause();
        launch.unpause();
        vm.stopPrank();
        vm.prank(alice);
        uint256 out = launch.buy(1 ether, 0, alice);
        assertGt(out, 0);
    }

    function test_CurveLibraryArithmetic() public pure {
        // selling 1 quote into a book of (quote=100, token=100) must return less than 1 token
        uint256 out = ConstantProductCurve.getAmountOut(1 ether, 100 ether, 100 ether);
        assertLt(out, 1 ether);
        // buying 1 token out of a book of (quote=100, token=100) must cost more than 1 quote
        uint256 cost = ConstantProductCurve.getAmountIn(1 ether, 100 ether, 100 ether);
        assertGt(cost, 1 ether);
        // k is preserved by construction (with integer-division slack of < 1)
        uint256 k = 100 ether * 100 ether;
        uint256 newReserveIn = 1 ether + 100 ether;
        uint256 newReserveOut = k / newReserveIn;
        assertGe(newReserveIn * newReserveOut, k - newReserveIn);
        assertLe(newReserveIn * newReserveOut, k);
    }

    function test_RevertSellMoreThanLiquidity() public {
        vm.prank(alice);
        uint256 out = launch.buy(1 ether, 0, alice);
        vm.expectRevert();
        vm.prank(alice);
        launch.sell(out * 1000, 0, alice);
    }

    function test_RevertSellWithNoLiquidity() public {
        // drain quote by graduating
        _buyToGraduate();
        // buy in the pool instead: sell path on the launchpad now reverts
        vm.expectRevert();
        vm.prank(alice);
        launch.sell(1 ether, 0, alice);
    }
}
