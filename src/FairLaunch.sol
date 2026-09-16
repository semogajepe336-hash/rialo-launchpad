// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "./interfaces/IERC20.sol";
import {IBurnable} from "./interfaces/IBurnable.sol";
import {LaunchpadErrors} from "./LaunchpadErrors.sol";
import {ConstantProductCurve} from "./ConstantProductCurve.sol";
import {TokenPool} from "./TokenPool.sol";

/// @title FairLaunch
/// @notice pump.fun-style fair launch on a bonding curve.
///
/// Value flow
/// ----------
/// The launchpad is the counter-party of every trade and always solvent by construction:
/// prices are computed directly from the launchpad's *actual* token and quote balances, so
/// the book can never promise more than it holds. Bought tokens leave immediately; sold
/// tokens are burned immediately. No funds are ever held on behalf of a user between txs.
///
/// Lifecycle
/// ---------
/// SEEDING -> owner seeds the curve with an initial quote amount. This sets the starting
///            price (seedQuote / tokenSupply) and opens trading.
/// CURVE    -> users buy/sell the project token against the launchpad's book (x*y=k over
///             the real balances). Buys raise the price, sells lower it.
/// LIVE     -> once the quote balance reaches `targetQuote`, the curve graduates: the whole
///             book is moved into a public constant-sum TokenPool at the final curve price,
///             and trading continues there.
///
/// Auth
/// ----
/// `owner` receives fees and is the only address that can seed, pause, withdraw fees and
/// change the fee. It cannot touch user balances, the curve math, or reverse a graduation.
contract FairLaunch {
    using ConstantProductCurve for uint256;

    /*//////////////////////////////////////////////////////////////
                              IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    IERC20 public immutable token; // project token (18 decimals)
    IERC20 public immutable quote; // quote asset (18 decimals), e.g. WETH on Sepolia
    address public immutable owner; // seed + fee + admin address
    uint256 public immutable targetQuote; // graduates when the quote balance >= this

    /*//////////////////////////////////////////////////////////////
                              STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Lifetime fees accrued, denominated in quote. owed to `owner`.
    uint256 public feesAccrued;

    enum Phase {
        Seeding,
        Curve,
        Live,
        Paused
    }
    Phase public phase = Phase.Seeding;
    TokenPool public pool; // address(0) until graduation
    uint256 public graduationRate; // quote per token (1e18) locked at graduation

    uint256 public feeBps = 100; // 1% on buys and sells

    /*//////////////////////////////////////////////////////////////
                              EVENTS
    //////////////////////////////////////////////////////////////*/

    event Seeded(address indexed by, uint256 quoteAmount, uint256 tokenBalance, uint256 startPrice);
    event Buy(address indexed buyer, uint256 quoteIn, uint256 tokenOut, uint256 priceAfter);
    event Sell(address indexed seller, uint256 tokenIn, uint256 quoteOut, uint256 priceAfter);
    event Graduated(address indexed pool, uint256 rate, uint256 reserveToken, uint256 reserveQuote);
    event FeesWithdrawn(address indexed to, uint256 amount);
    event Paused();
    event Unpaused();
    event FeeUpdated(uint256 oldBps, uint256 newBps);

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyOwner() {
        if (msg.sender != owner) revert LaunchpadErrors.Unauthorized();
        _;
    }

    modifier when(Phase p) {
        if (phase == Phase.Paused) revert LaunchpadErrors.Paused();
        if (phase != p) {
            if (p == Phase.Curve) revert LaunchpadErrors.NotInCurvePhase();
            revert LaunchpadErrors.NotInLivePhase();
        }
        _;
    }

    /// @dev For `Live`-only functions that must also work while the curve is still open.
    modifier whenLive() {
        if (phase == Phase.Paused) revert LaunchpadErrors.Paused();
        if (phase == Phase.Seeding) revert LaunchpadErrors.NotInCurvePhase();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param _token  project token. Must be burnable and the launchpad must hold the
    ///                entire fair-launch supply (minted to this contract before trading).
    /// @param _quote  quote asset (e.g. WETH). Buyers must approve the launchpad.
    /// @param _target quote balance at which the curve graduates.
    constructor(IERC20 _token, IERC20 _quote, uint256 _target) {
        if (address(_token) == address(0) || address(_quote) == address(0) || _target == 0) {
            revert LaunchpadErrors.InvalidConfig();
        }
        token = _token;
        quote = _quote;
        owner = msg.sender;
        targetQuote = _target;
    }

    /*//////////////////////////////////////////////////////////////
                              SEEDING
    //////////////////////////////////////////////////////////////*/

    /// @notice Seeds the curve with `quoteAmount` of the quote asset, setting the starting
    ///         price. Callable once by the owner. The seed becomes part of the book and is
    ///         redeemable by no one; it is the curve's initial liquidity.
    function seed(uint256 quoteAmount) external onlyOwner when(Phase.Seeding) {
        if (quoteAmount == 0) revert LaunchpadErrors.ZeroAmount();
        if (!quote.transferFrom(msg.sender, address(this), quoteAmount)) revert LaunchpadErrors.TransferFailed();
        phase = Phase.Curve;
        emit Seeded(msg.sender, quoteAmount, token.balanceOf(address(this)), price());
    }

    /*//////////////////////////////////////////////////////////////
                         CURVE: BUY / SELL
    //////////////////////////////////////////////////////////////*/

    /// @notice Buy with exactly `quoteIn` quote asset. Tokens are sent to `to`.
    /// @dev Caller must have approved the launchpad for `quoteIn`.
    function buy(uint256 quoteIn, uint256 minTokenOut, address to)
        external
        when(Phase.Curve)
        returns (uint256 tokenOut)
    {
        if (quoteIn == 0 || to == address(0)) revert LaunchpadErrors.ZeroAmount();

        // snapshot the book BEFORE pulling the quote, so `previewBuy` (which cannot pull) matches
        (uint256 rToken, uint256 rQuote) = getReserves();
        if (rToken == 0 || rQuote == 0) revert LaunchpadErrors.InsufficientLiquidity();

        // pull quote first, then settle the fee against the received amount
        if (!quote.transferFrom(msg.sender, address(this), quoteIn)) revert LaunchpadErrors.TransferFailed();
        uint256 netIn = _takeFee(quoteIn);

        // buy: quote in, token out
        tokenOut = ConstantProductCurve.getAmountOut(netIn, rQuote, rToken);
        if (tokenOut < minTokenOut) revert LaunchpadErrors.SlippageExceeded();

        if (!token.transfer(to, tokenOut)) revert LaunchpadErrors.TransferFailed();
        emit Buy(to, quoteIn, tokenOut, price());

        _maybeGraduate();
    }

    /// @notice Sell `tokenIn` project tokens for the quote asset.
    /// @dev Caller must have approved the launchpad for `tokenIn`.
    function sell(uint256 tokenIn, uint256 minQuoteOut, address to)
        external
        when(Phase.Curve)
        returns (uint256 quoteOut)
    {
        if (tokenIn == 0 || to == address(0)) revert LaunchpadErrors.ZeroAmount();

        // snapshot the book BEFORE pulling the tokens, symmetric with `buy`
        (uint256 rToken, uint256 rQuote) = getReserves();
        if (rToken == 0 || rQuote == 0) revert LaunchpadErrors.InsufficientLiquidity();

        if (!token.transferFrom(msg.sender, address(this), tokenIn)) revert LaunchpadErrors.TransferFailed();

        // sell: token in, quote out
        quoteOut = ConstantProductCurve.getAmountOut(tokenIn, rToken, rQuote);
        if (quoteOut > rQuote) revert LaunchpadErrors.InsufficientLiquidity();
        // _takeFee returns the net amount, so assign directly (do not subtract again)
        uint256 netOut = _takeFee(quoteOut);
        if (netOut < minQuoteOut) revert LaunchpadErrors.SlippageExceeded();
        // burn what was sold so the curve recedes, then pay out
        IBurnable(address(token)).burn(tokenIn);
        if (!quote.transfer(to, netOut)) revert LaunchpadErrors.TransferFailed();
        emit Sell(to, tokenIn, netOut, price());
    }
    /*//////////////////////////////////////////////////////////////
                         GRADUATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Anyone may graduate once the book holds >= targetQuote of the quote asset.
    function graduate() external when(Phase.Curve) returns (TokenPool _pool) {
        if (quote.balanceOf(address(this)) - feesAccrued < targetQuote) revert LaunchpadErrors.NotGraduated();
        _pool = _graduate();
    }

    function _maybeGraduate() internal {
        if (quote.balanceOf(address(this)) - feesAccrued >= targetQuote) _graduate();
    }

    function _graduate() internal returns (TokenPool _pool) {
        // rate locked from the final curve price so the pool is price-continuous
        uint256 rate = price();
        if (rate == 0) revert LaunchpadErrors.InsufficientLiquidity();

        uint256 rToken = token.balanceOf(address(this));
        uint256 rQuote = quote.balanceOf(address(this)) - feesAccrued;

        _pool = new TokenPool(token, quote, rate);
        pool = _pool;
        graduationRate = rate;
        phase = Phase.Live;

        require(token.approve(address(_pool), rToken), "A0");
        require(quote.approve(address(_pool), rQuote), "A1");
        _pool.initialize(uint112(rToken), uint112(rQuote));

        (uint256 p0, uint256 p1) = _pool.getReserves();
        emit Graduated(address(_pool), rate, p0, p1);
    }

    /*//////////////////////////////////////////////////////////////
                              ADMIN
    //////////////////////////////////////////////////////////////*/

    function pause() external onlyOwner when(Phase.Curve) {
        phase = Phase.Paused;
        emit Paused();
    }

    function unpause() external onlyOwner {
        if (phase != Phase.Paused) revert LaunchpadErrors.InvalidConfig();
        phase = Phase.Curve;
        emit Unpaused();
    }

    function setFeeBps(uint256 newBps) external onlyOwner {
        if (newBps > 1000) revert LaunchpadErrors.InvalidConfig(); // cap 10%
        emit FeeUpdated(feeBps, newBps);
        feeBps = newBps;
    }

    /// @notice Withdraws accrued fees. Callable any time trading is open, so the book never
    ///         runs dry. Fees are accounted separately from the book at all times.
    function withdrawFees(address to) external onlyOwner whenLive returns (uint256 amount) {
        if (to == address(0)) revert LaunchpadErrors.ZeroAddress();
        amount = feesAccrued;
        feesAccrued = 0;
        if (amount > 0 && !quote.transfer(to, amount)) revert LaunchpadErrors.TransferFailed();
        emit FeesWithdrawn(to, amount);
    }

    /*//////////////////////////////////////////////////////////////
                              VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Live book: token side and quote side of the curve. Zeroes out after graduation
    ///         because the whole book has moved into the pool.
    function getReserves() public view returns (uint256 reserveToken, uint256 reserveQuote) {
        if (phase != Phase.Curve) return (0, 0);
        reserveToken = token.balanceOf(address(this));
        reserveQuote = quote.balanceOf(address(this)) - feesAccrued;
    }

    function price() public view returns (uint256) {
        (uint256 rToken, uint256 rQuote) = getReserves();
        return ConstantProductCurve.pricePerToken(rQuote, rToken);
    }

    /// @notice Preview of a buy at the current book.
    function previewBuy(uint256 quoteIn) external view returns (uint256 tokenOut, uint256 priceAfter) {
        (uint256 rToken, uint256 rQuote) = getReserves();
        if (quoteIn == 0 || rToken == 0 || rQuote == 0) return (0, price());
        uint256 netIn = (quoteIn * (10_000 - feeBps)) / 10_000;
        tokenOut = ConstantProductCurve.getAmountOut(netIn, rQuote, rToken);
        priceAfter = ConstantProductCurve.pricePerToken(rQuote + netIn, rToken - tokenOut);
    }

    /// @notice Preview of a sell at the current book.
    function previewSell(uint256 tokenIn) external view returns (uint256 quoteOut, uint256 priceAfter) {
        (uint256 rToken, uint256 rQuote) = getReserves();
        if (tokenIn == 0 || rQuote == 0) return (0, price());
        quoteOut = ConstantProductCurve.getAmountOut(tokenIn, rToken, rQuote);
        priceAfter = ConstantProductCurve.pricePerToken(rQuote - quoteOut, rToken + tokenIn);
    }

    /*//////////////////////////////////////////////////////////////
                              INTERNAL
    //////////////////////////////////////////////////////////////*/

    /// @dev Deducts `feeBps` from `amount`, crediting the fee in quote. Returns the net amount.
    function _takeFee(uint256 amount) internal returns (uint256 net) {
        uint256 fee = (amount * feeBps) / 10_000;
        feesAccrued += fee;
        net = amount - fee;
    }
}
