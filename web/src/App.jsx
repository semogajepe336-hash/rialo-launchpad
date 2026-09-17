import {useCallback, useEffect, useState} from "react";
import {
  BrowserProvider,
  Contract,
  ethers,
  formatEther,
  parseEther,
  ZeroAddress,
} from "ethers";
import {ADDRESSES, ABIS, SEPOLIA_CHAIN_ID, CHAIN_NAME, FALLBACK_RPCS} from "./config.js";

const PHASE = {0: "Seeding", 1: "Curve", 2: "Live", 3: "Paused"};

function fmtRLO(v) {
  return (Number(v) / 1e18).toLocaleString("en-US", {maximumFractionDigits: 2});
}
function fmtUnits(v, decimals = 18, digits = 4) {
  if (decimals === 0) return Number(v).toLocaleString("en-US");
  return (Number(v) / 10 ** decimals).toLocaleString("en-US", {maximumFractionDigits: digits});
}
function short(a) {
  if (!a || a === ZeroAddress) return "—";
  return `${a.slice(0, 6)}…${a.slice(-4)}`;
}

export default function App() {
  const [signer, setSigner] = useState(null);
  const [account, setAccount] = useState(null);
  const [chainOk, setChainOk] = useState(false);
  const [connecting, setConnecting] = useState(false);

  const [launch, setLaunch] = useState(null);
  const [roLaunch, setRoLaunch] = useState(null);

  const [phase, setPhase] = useState(null);
  const [price, setPrice] = useState(0n);
  const [reserves, setReserves] = useState([0n, 0n]);
  const [target, setTarget] = useState(0n);
  const [fees, setFees] = useState(0n);
  const [feeBps, setFeeBps] = useState(0);
  const [poolAddr, setPoolAddr] = useState(ZeroAddress);
  const [gradRate, setGradRate] = useState(0n);
  const [priceChange, setPriceChange] = useState(0);

  const [balQuote, setBalQuote] = useState(0n);
  const [balToken, setBalToken] = useState(0n);
  const [allowance, setAllowance] = useState(0n);

  const [tab, setTab] = useState("buy");
  const [buyAmt, setBuyAmt] = useState("");
  const [sellAmt, setSellAmt] = useState("");
  const [previewOut, setPreviewOut] = useState(0n);
  const [previewIn, setPreviewIn] = useState(0n);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState("");
  const [okMsg, setOkMsg] = useState("");

  const [poolReserves, setPoolReserves] = useState([0n, 0n]);

  const connect = useCallback(async () => {
    if (!window.ethereum) {
      setErr("No wallet found. Install MetaMask or use a dapp browser.");
      return;
    }
    setConnecting(true);
    try {
      const p = new BrowserProvider(window.ethereum);
      await p.send("eth_requestAccounts", []);
      const s = await p.getSigner();
      const net = await p.getNetwork();
      setSigner(s);
      setAccount(await s.getAddress());
      setChainOk(Number(net.chainId) === SEPOLIA_CHAIN_ID);
    } catch (e) {
      setErr(String(e.shortMessage || e.message || e));
    } finally {
      setConnecting(false);
    }
  }, []);

  useEffect(() => {
    if (!window.ethereum) return;
    const onChain = () => window.location.reload();
    const onAccounts = (accs) => (accs.length ? window.location.reload() : setAccount(null));
    window.ethereum.on?.("chainChanged", onChain);
    window.ethereum.on?.("accountsChanged", onAccounts);
    return () => {
      window.ethereum.removeListener?.("chainChanged", onChain);
      window.ethereum.removeListener?.("accountsChanged", onAccounts);
    };
  }, []);

  useEffect(() => {
    if (!signer) return;
    setLaunch(new Contract(ADDRESSES.fairlaunch, ABIS.fairlaunch, signer));
  }, [signer]);

  // read-only from public RPCs so the panel works before connecting
  useEffect(() => {
    let cancelled = false;
    (async () => {
      for (const url of FALLBACK_RPCS) {
        try {
          const p = new ethers.JsonRpcProvider(url, SEPOLIA_CHAIN_ID, {staticNetwork: true});
          const l = new ethers.Contract(ADDRESSES.fairlaunch, ABIS.fairlaunch, p);
          await l.phase();
          if (!cancelled) setRoLaunch(l);
          return;
        } catch {
          /* next */
        }
      }
    })();
    return () => {
      cancelled = true;
    };
  }, []);

  const refresh = useCallback(async () => {
    const l = launch || roLaunch;
    if (!l) return;
    try {
      const [p, r, t, f, fb, ph, pa, gr] = await Promise.all([
        l.price(),
        l.getReserves(),
        l.targetQuote(),
        l.feesAccrued(),
        l.feeBps(),
        l.phase(),
        l.pool(),
        l.graduationRate(),
      ]);
      setPrice((old) => {
        if (old > 0n) setPriceChange(Number((p * 10000n) / old - 10000n) / 100);
        return p;
      });
      setReserves(r);
      setTarget(t);
      setFees(f);
      setFeeBps(Number(fb));
      setPhase(Number(ph));
      setPoolAddr(pa);
      setGradRate(gr);
      if (launch && ABIS.erc20) {
        const q = new Contract(ADDRESSES.quote, ABIS.erc20, l.runner);
        const tk = new Contract(ADDRESSES.token, ABIS.erc20, l.runner);
        const [bq, bt, al] = await Promise.all([
          q.balanceOf(account || ZeroAddress),
          tk.balanceOf(account || ZeroAddress),
          q.allowance(account || ZeroAddress, ADDRESSES.fairlaunch),
        ]);
        setBalQuote(bq);
        setBalToken(bt);
        setAllowance(al);
      }
      setErr("");
    } catch (e) {
      setErr(String(e.shortMessage || e.message || e));
    }
  }, [launch, roLaunch, account]);

  useEffect(() => {
    refresh();
    if (!launch && !roLaunch) return;
    const iv = setInterval(refresh, 7000);
    return () => clearInterval(iv);
  }, [refresh, launch, roLaunch]);

  // pool reserves
  useEffect(() => {
    if (!poolAddr || poolAddr === ZeroAddress) {
      setPoolReserves([0n, 0n]);
      return;
    }
    const runner = signer || null;
    let c;
    if (runner) {
      c = new Contract(poolAddr, ABIS.tokenPool, runner);
    } else {
      const rpc = new ethers.JsonRpcProvider(FALLBACK_RPCS[0], SEPOLIA_CHAIN_ID, {
        staticNetwork: true,
      });
      c = new Contract(poolAddr, ABIS.tokenPool, rpc);
    }
    c.getReserves()
      .then(setPoolReserves)
      .catch(() => setPoolReserves([0n, 0n]));
  }, [poolAddr, signer]);

  // previews
  useEffect(() => {
    if (!launch) return setPreviewOut(0n);
    if (buyAmt && Number(buyAmt) > 0) {
      launch
        .previewBuy(parseEther(buyAmt))
        .then((r) => setPreviewOut(r[0]))
        .catch(() => setPreviewOut(0n));
    } else setPreviewOut(0n);
  }, [buyAmt, launch, price, reserves]);

  useEffect(() => {
    if (!launch) return setPreviewIn(0n);
    if (sellAmt && Number(sellAmt) > 0) {
      launch
        .previewSell(parseEther(sellAmt))
        .then((r) => setPreviewIn(r[0]))
        .catch(() => setPreviewIn(0n));
    } else setPreviewIn(0n);
  }, [sellAmt, launch, price, reserves]);

  const ensureApproval = async () => {
    if (allowance >= parseEther(buyAmt || "0")) return true;
    const q = new Contract(ADDRESSES.quote, ABIS.erc20, signer);
    const tx = await q.approve(ADDRESSES.fairlaunch, parseEther(buyAmt));
    await tx.wait();
    return true;
  };

  const doBuy = async () => {
    setBusy(true);
    setErr("");
    setOkMsg("");
    try {
      if (!Number(buyAmt) || Number(buyAmt) <= 0) throw Error("Enter an amount");
      await ensureApproval();
      const tx = await launch.buy(parseEther(buyAmt), 0n, account);
      await tx.wait();
      setOkMsg(`Bought ${fmtRLO(previewOut)} RLO`);
      setBuyAmt("");
      await refresh();
    } catch (e) {
      setErr(String(e.shortMessage || e.reason || e.message || e));
    } finally {
      setBusy(false);
    }
  };

  const doSell = async () => {
    setBusy(true);
    setErr("");
    setOkMsg("");
    try {
      if (!Number(sellAmt) || Number(sellAmt) <= 0) throw Error("Enter an amount");
      const tx = await launch.sell(parseEther(sellAmt), 0n, account);
      await tx.wait();
      setOkMsg(`Sold ${fmtRLO(parseEther(sellAmt))} RLO for ${fmtUnits(previewIn)} WSETH`);
      setSellAmt("");
      await refresh();
    } catch (e) {
      setErr(String(e.shortMessage || e.reason || e.message || e));
    } finally {
      setBusy(false);
    }
  };

  const doSeed = async () => {
    setBusy(true);
    setErr("");
    try {
      const q = new Contract(ADDRESSES.quote, ABIS.erc20, signer);
      const a = await q.approve(ADDRESSES.fairlaunch, parseEther("10"));
      await a.wait();
      const s = await launch.seed(parseEther("10"));
      await s.wait();
      setOkMsg("Curve seeded with 10 WSETH");
      await refresh();
    } catch (e) {
      setErr(String(e.shortMessage || e.reason || e.message || e));
    } finally {
      setBusy(false);
    }
  };

  const isOwner =
    account && account.toLowerCase() === (ADDRESSES.ownerWallet || "").toLowerCase();
  const progress = target > 0n ? Number((reserves[1] * 10000n) / target) / 100 : 0;
  const phaseName = phase === null ? "…" : PHASE[phase];
  const livePrice = phase === 2 ? gradRate : price;

  return (
    <>
      <div className="topbar">
        <div className="topbar-in">
          <div className="brand">
            <span className="logo">◈</span> Rialo Launchpad
          </div>
          <div className="spacer" />
          <span className="chain-pill">
            <span className="chain-dot" /> {CHAIN_NAME}
          </span>
          {account ? (
            <span className="chain-pill mono">{short(account)}</span>
          ) : (
            <button className="btn-g" onClick={connect} disabled={connecting}>
              {connecting ? "Connecting…" : "Connect wallet"}
            </button>
          )}
        </div>
      </div>

      <div className="wrap">
        <div className="hero">
          <h1>
            Fair launches on the <span className="grad">bonding curve</span>
          </h1>
          <p>
            Buy pushes the price up the curve, sell pushes it back down. When the curve fills, the
            market graduates into a permanently liquid pool. No team allocation, no presale.
          </p>
        </div>

        <div className="stats">
          <div className="stat">
            <div className="k">{phase === 2 ? "Pool price" : "Curve price"}</div>
            <div className="v pulse" style={livePrice === 0n ? undefined : {animation: "none"}}>
              {fmtUnits(livePrice, 18, 6)}
            </div>
            <div className="sub">
              WSETH per RLO{" "}
              {priceChange !== 0 && (
                <span className={priceChange > 0 ? "up-c" : "down-c"}>
                  {priceChange > 0 ? "▲" : "▼"} {Math.abs(priceChange).toFixed(2)}%
                </span>
              )}
            </div>
          </div>
          <div className="stat">
            <div className="k">Market cap</div>
            <div className="v">{fmtUnits(reserves[1] + (phase === 2 ? poolReserves[1] : 0n))}</div>
            <div className="sub">WSETH pooled</div>
          </div>
          <div className="stat">
            <div className="k">Liquidity</div>
            <div className="v">{fmtRLO(phase === 2 ? poolReserves[0] : reserves[0])}</div>
            <div className="sub">RLO {phase === 2 ? "in pool" : "on curve"}</div>
          </div>
          <div className="stat">
            <div className="k">Fees earned</div>
            <div className="v">{fmtUnits(fees)}</div>
            <div className="sub">{feeBps / 100}% on sells</div>
          </div>
        </div>

        <div className="chart-card card">
          <div className="card-h">
            <h3>{phase === 2 ? "Graduated — curve filled" : "Bonding curve progress"}</h3>
            <span
              className={`badge ${phaseName.toLowerCase()}`}
              style={phase === null ? {visibility: "hidden"} : undefined}
            >
              <span className="bdot" /> {phaseName}
            </span>
          </div>
          <div className="chart">
            <div className="grid-lines" />
            <div
              className="fill"
              style={{width: phase === 2 ? "100%" : `${Math.min(100, progress)}%`}}
            />
            <span className="cap">
              {phase === 2 ? "100% · live" : `${progress.toFixed(2)}% to graduation`}
            </span>
            <span className="progress-label">
              curve target {fmtUnits(target)} WSETH · fee {feeBps / 100}%
            </span>
          </div>
        </div>

        <div className="grid-main" style={{marginTop: 18}}>
          {phase === 2 ? (
            <div className="card">
              <div className="card-h">
                <h3>Live market</h3>
                <span className="badge live">
                  <span className="bdot" /> Graduated
                </span>
              </div>
              <div className="card-b">
                <div className="pool-row">
                  <span className="k">Pool address</span>
                  <span className="v mono">{short(poolAddr)}</span>
                </div>
                <div className="pool-row">
                  <span className="k">Rate</span>
                  <span className="v">
                    {fmtUnits(gradRate, 18, 8)} <small className="up-c">WSETH/RLO</small>
                  </span>
                </div>
                <div className="pool-row">
                  <span className="k">Pool RLO</span>
                  <span className="v">{fmtRLO(poolReserves[0])}</span>
                </div>
                <div className="pool-row">
                  <span className="k">Pool WSETH</span>
                  <span className="v">{fmtUnits(poolReserves[1])}</span>
                </div>
                <p className="note">
                  The curve is closed. Trade directly in the pool: approve the pool for the input
                  token, then call <code>swapExactToken0ForToken1</code> /
                  <code>swapExactToken1ForToken0</code>.
                </p>
              </div>
            </div>
          ) : (
            <div className="card">
              <div className="card-h">
                <h3>Trade</h3>
                <span className="badge curve">
                  <span className="bdot" /> {phaseName}
                </span>
              </div>
              <div className="card-b">
                <div className="tabs">
                  <button
                    className={`tab ${tab === "buy" ? "on" : ""}`}
                    onClick={() => setTab("buy")}
                  >
                    Buy
                  </button>
                  <button
                    className={`tab ${tab === "sell" ? "on" : ""}`}
                    onClick={() => setTab("sell")}
                  >
                    Sell
                  </button>
                </div>

                {tab === "buy" ? (
                  <>
                    <div className="field">
                      <label>
                        You pay
                        <span className="bal">bal {fmtUnits(balQuote)} WSETH</span>
                      </label>
                      <div className="inp-wrap">
                        <input
                          type="number"
                          min="0"
                          step="0.01"
                          placeholder="0.0"
                          value={buyAmt}
                          onChange={(e) => setBuyAmt(e.target.value)}
                        />
                        <span className="suffix">WSETH</span>
                      </div>
                    </div>
                    <div className="conv">
                      <span className="arrow">↓</span>
                      <span className="out">≈ {fmtRLO(previewOut)} RLO</span>
                    </div>
                    <button
                      className="btn btn-p"
                      disabled={busy || !account}
                      onClick={doBuy}
                    >
                      {busy ? "Confirming…" : "Buy RLO"}
                    </button>
                  </>
                ) : (
                  <>
                    <div className="field">
                      <label>
                        You sell
                        <span className="bal">bal {fmtRLO(balToken)} RLO</span>
                      </label>
                      <div className="inp-wrap">
                        <input
                          type="number"
                          min="0"
                          step="0.01"
                          placeholder="0.0"
                          value={sellAmt}
                          onChange={(e) => setSellAmt(e.target.value)}
                        />
                        <span className="suffix">RLO</span>
                      </div>
                    </div>
                    <div className="conv">
                      <span className="arrow">↓</span>
                      <span className="out">≈ {fmtUnits(previewIn)} WSETH</span>
                    </div>
                    <button
                      className="btn btn-sell"
                      disabled={busy || !account}
                      onClick={doSell}
                    >
                      {busy ? "Confirming…" : "Sell RLO"}
                    </button>
                  </>
                )}

                {account && !chainOk && (
                  <div className="err" style={{marginTop: 14}}>
                    Wrong network — switch to {CHAIN_NAME} (chain id {SEPOLIA_CHAIN_ID}).
                  </div>
                )}
              </div>
            </div>
          )}

          <div>
            {isOwner && phase === 0 && (
              <div className="card admin-card" style={{marginTop: 0}}>
                <div className="card-h">
                  <h3>Owner · seed curve</h3>
                </div>
                <div className="card-b">
                  <p className="note" style={{marginTop: 0, marginBottom: 13}}>
                    Seeding sets the starting price and opens trading.
                  </p>
                  <button className="btn btn-p" disabled={busy} onClick={doSeed}>
                    Seed 10 WSETH
                  </button>
                </div>
              </div>
            )}

            {isOwner && phase === 1 && (
              <div className="card admin-card" style={{marginTop: 0}}>
                <div className="card-h">
                  <h3>Owner</h3>
                </div>
                <div className="card-b">
                  <div className="admin">
                    <button
                      className="btn-g"
                      disabled={busy}
                      onClick={async () => {
                        setBusy(true);
                        try {
                          const tx = await launch.graduate();
                          await tx.wait();
                          setOkMsg("Graduated — pool is live.");
                          await refresh();
                        } catch (e) {
                          setErr(String(e.shortMessage || e.reason || e.message || e));
                        } finally {
                          setBusy(false);
                        }
                      }}
                    >
                      Graduate manually
                    </button>
                    <button
                      className="btn-g"
                      disabled={busy}
                      onClick={async () => {
                        setBusy(true);
                        try {
                          const tx = await launch.withdrawFees(account);
                          await tx.wait();
                          setOkMsg("Fees withdrawn.");
                          await refresh();
                        } catch (e) {
                          setErr(String(e.shortMessage || e.reason || e.message || e));
                        } finally {
                          setBusy(false);
                        }
                      }}
                    >
                      Withdraw fees
                    </button>
                  </div>
                  <p className="note">
                    Graduation also fires automatically on the buy that fills the curve.
                  </p>
                </div>
              </div>
            )}

            <div className="card" style={{marginTop: 18}}>
              <div className="card-h">
                <h3>Contracts</h3>
              </div>
              <div className="card-b">
                <div className="pool-row">
                  <span className="k">FairLaunch</span>
                  <span className="v mono">{short(ADDRESSES.fairlaunch)}</span>
                </div>
                <div className="pool-row">
                  <span className="k">Token (RLO)</span>
                  <span className="v mono">{short(ADDRESSES.token)}</span>
                </div>
                <div className="pool-row">
                  <span className="k">Quote (WSETH)</span>
                  <span className="v mono">{short(ADDRESSES.quote)}</span>
                </div>
                {poolAddr !== ZeroAddress && (
                  <div className="pool-row">
                    <span className="k">Pool</span>
                    <span className="v mono">{short(poolAddr)}</span>
                  </div>
                )}
              </div>
            </div>
          </div>
        </div>

        {err && <div className="err">⚠ {err}</div>}
        {okMsg && <div className="ok">✓ {okMsg}</div>}

        <div className="foot">
          <span>
            40/40 property tests passing · audited invariants: no-free-money, sandwich-resistant,
            fee-isolated
          </span>
          <span>
            <a
              href="https://sepolia.etherscan.io/address/" 
              target="_blank"
              rel="noreferrer"
            >
              Etherscan
            </a>{" "}
            · source in repo <code className="mono">/rialo-launchpad</code>
          </span>
        </div>
      </div>
    </>
  );
}
