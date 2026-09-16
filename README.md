# Rialo Fair Launch (Sepolia testnet)

pump.fun-style fair launch: a constant-product bonding curve that graduates into a
constant-sum pool once the curve target is filled. Fully written, tested, deployed and
exercised end-to-end on Sepolia.

## Deployed contracts (chain id 11155111)

| Contract    | Address                                          |
| ----------- | ------------------------------------------------ |
| FairLaunch  | `0xb042C7a5aB6D54F54d02ee5bDE33a63CA20C08CC`      |
| Token (RLO) | `0xB9dd17e7dcF276A59beF445b1Aa4B9844A82243D`      |
| Quote (WSETH) | `0xC71FbaF27A861624F9695F9BEF12f3Ea58FbF68A`    |
| Pool (post-graduation) | `0x6A1B414f3C5bAd83A5A2155Cc884c54A2638935b` |

Explorer: https://sepolia.etherscan.io

## How it works

1. **Seed** — owner approves quote and calls `seed(amount)`. This sets the starting price
   and moves the launchpad from `Seeding` to `Curve`.
2. **Curve** — anyone buys the project token with quote (`buy`) and sells it back (`sell`).
   Price follows `x * y = k` against the launchpad's own balances, so buying raises the
   price and selling lowers it. A fee (default 1%) is taken on sells and is tracked
   separately from the curve, so it can be withdrawn without draining the book.
3. **Graduation** — once the quote side of the curve reaches `targetQuote` (100 WSETH),
   the buy that crosses the line automatically deploys a `TokenPool`, seeds it with the
   whole curve at the market rate, and moves to `Live`. From then on all trading happens
   in the pool at a fixed rate; the launchpad curve is closed.
4. **Live** — trade through the pool directly (`swapExactToken0ForToken1` and the reverse).
   The launchpad still tracks accrued fees for the owner.

Phases: `0 = Seeding, 1 = Curve, 2 = Live, 3 = Paused`.

## Security properties (verified by 40 tests)

- **No reentrancy on payout**: state (reserves, phase, fees) is written before any
  `transfer` to the caller, following the checks-effects-interactions pattern.
- **No free money**: 20-cycle buy/sell fuzz test proves every round trip strictly costs
  the caller; a sandwich test proves a pump-and-dump cannot make the protocol insolvent.
- **No infinite mint / overflow**: token out is bounded by the book; all math uses
  checked Solidity 0.8 arithmetic and OpenZeppelin-style `SafeMath`-free operations.
- **Pool invariant**: the constant-sum pool's reserves are set once at graduation and the
  rate never changes, so the pool cannot be manipulated after the fact.
- **Fees never drain the curve**: `feesAccrued` is excluded from every reserve read and
  every price computation.
- **Owner is bounded**: the owner can seed, pause, withdraw fees and set the fee — it
  cannot mint tokens out of thin air, cannot move user funds, and cannot change the
  graduation target after seeding.

## Layout

```
src/
  FairLaunch.sol          the curve contract: seed, buy, sell, graduate, fees, pause
  TokenPool.sol           constant-sum pool deployed at graduation
  ConstantProductCurve.sol  pure x*y=k math (getAmountIn / getAmountOut / pricePerToken)
  LaunchpadErrors.sol     custom errors
  interfaces/             IERC20, IBurnable
  mocks/MockToken.sol     the RLO + WSETH test tokens (mintable, burnable)
test/
  FairLaunch.t.sol        37 property + unit tests
  EndToEnd.t.sol          full lifecycle, sandwich resistance, no-free-money fuzz
script/
  DeployFairLaunch.s.sol  deploys tokens + launchpad and seeds the curve
web/                      vite + ethers frontend, reads the curve live
```

## Commands

```bash
forge test                 # 40 tests, all passing
forge test -vvv            # with traces
forge coverage             # line/branch coverage
forge script script/DeployFairLaunch.s.sol:DeployFairLaunch \
  --rpc-url $SEPOLIA_RPC_URL --private-key $PK --broadcast

cd web && npm install && npm run dev    # frontend on http://localhost:5173
```

## Notes

- The quote token (`WSETH`) and project token (`RLO`) are both test tokens with a public
  `mint`, which is intentional for a testnet demo. On mainnet the quote would be real
  WETH and the project token would be deployed without a public mint.
- The curve prices off the launchpad's **actual token balance**, not a virtual number.
  Sold tokens are really burned, so the book always matches the balance and graduation
  seeds the pool with exactly what it holds.
