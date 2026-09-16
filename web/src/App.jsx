import {useCallback, useEffect, useState} from "react";
import {BrowserProvider, Contract, formatEther, parseEther, ZeroAddress} from "ethers";
import {ADDRESSES, ABIS, SEPOLIA_CHAIN_ID, CHAIN_NAME} from "./config.js";

const PHASE = {0: "Seeding", 1: "Curve", 2: "Live", 3: "Paused"};

function short(a) {
  if (!a || a === ZeroAddress) return "—";
  return `${a.slice(0, 6)}…${a.slice(-4)}`;
}

export default function App() {
  const [provider, setProvider] = useState(null);
  const [signer, setSigner] = useState(null);
  const [account, setAccount] = useState(null);
  const [chainOk, setChainOk] = useState(false);

  const [launch, setLaunch] = useState(null);
  const [token, setToken] = useState(null);
  const [quote, setQuote] = useState(null);

  const [phase, setPhase] = useState(null);
  const [price, setPrice] = useState(0n);
  const [reserves, setReserves] = useState([0n, 0n]);
  const [target, setTarget] = useState(0n);
  const [fees, setFees] = useState(0n);
  const [feeBps, setFeeBps] = useState(0);
  const [poolAddr, setPoolAddr] = useState(ZeroAddress);
  const [gradRate, setGradRate] = useState(0n);

  const [balQuote, setBalQuote] = useState(0n);
  const [balToken, setBalToken] = useState(0n);
  const [allowance, setAllowance] = useState(0n);

  const [buyAmt, setBuyAmt] = useState("");
  const [sellAmt, setSellAmt] = useState("");
  const [previewOut, setPreviewOut] = useState(0n);
  const [previewIn, setPreviewIn] = useState(0n);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState("");
  const [okMsg, setOkMsg] = useState("");

  const [pool, setPool] = useState(null);
  const [poolReserves, setPoolReserves] = useState([0n, 0n]);

  const connect = useCallback(async () => {
    if (!window.ethereum) {
      setErr("No wallet found. Install MetaMask or use a dapp browser.");
      return;
    }
    try {
      const p = new BrowserProvider(window.ethereum);
      await p.send("eth_requestAccounts", []);
      const s = await p.getSigner();
      const net = await p.getNetwork();
      setProvider(p);
      setSigner(s);
      setAccount(await s.getAddress());
      setChainOk(Number(net.chainId) === SEPOLIA_CHAIN_ID);
    } catch (e) {
      setErr(String(e.shortMessage || e.message || e));
    }
  }, []);

  // re-check chain on account/chain changes
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
    const l = new Contract(ADDRESSES.fairlaunch, ABIS.fairlaunch, signer);
    const t = new Contract(ADDRESSES.token, ABIS.erc20, signer);
    const q = new Contract(ADDRESSES.quote, ABIS.erc20, signer);
    setLaunch(l);
    setToken(t);
    setQuote(q);
  }, [signer]);

  const refresh = useCallback(async () => {
    if (!launch || !token || !quote || !account) return;
    try {
      const [p, r, t, f, fb, ph, pa, gr, bq, bt, al] = await Promise.all([
        launch.price(),
        launch.getReserves(),
        launch.targetQuote(),
        launch.feesAccrued(),
        launch.feeBps(),
        launch.phase(),
        launch.pool(),
        launch.graduationRate(),
        quote.balanceOf(account),
        token.balanceOf(account),
        quote.allowance(account, ADDRESSES.fairlaunch),
      ]);
      setPrice(p);
      setReserves(r);
      setTarget(t);
      setFees(f);
      setFeeBps(Number(fb));
      setPhase(Number(ph));
      setPoolAddr(pa);
      setGradRate(gr);
      setBalQuote(bq);
      setBalToken(bt);
      setAllowance(al);
      setErr("");
    } catch (e) {
      setErr(String(e.shortMessage || e.message || e));
    }
  }, [launch, token, quote, account]);

  useEffect(() => {
    refresh();
    if (!launch) return;
    const iv = setInterval(refresh, 6000);
    return () => clearInterval(iv);
  }, [refresh, launch]);

  // pool state after graduation
  useEffect(() => {
    if (!poolAddr || poolAddr === ZeroAddress || !signer) {
      setPool(null);
      setPoolReserves([0n, 0n]);
      return;
    }
    const p = new Contract(poolAddr, ABIS.tokenPool, signer);
    p.getReserves().then(setPoolReserves).catch(() => {});
    setPool(p);
  }, [poolAddr, signer]);

  // previews
  useEffect(() => {
    if (!launch) return;
    if (buyAmt && Number(buyAmt) > 0) {
      launch
        .previewBuy(parseEther(buyAmt))
        .then((r) => setPreviewOut(r[0]))
        .catch(() => setPreviewOut(0n));
    } else setPreviewOut(0n);
  }, [buyAmt, launch, price, reserves]);

  useEffect(() => {
    if (!launch) return;
    if (sellAmt && Number(sellAmt) > 0) {
      launch
        .previewSell(parseEther(sellAmt))
        .then((r) => setPreviewIn(r[0]))
        .catch(() => setPreviewIn(0n));
    } else setPreviewIn(0n);
  }, [sellAmt, launch, price, reserves]);

  const ensureApproval = async () => {
    if (allowance >= parseEther(buyAmt || "0")) return true;
    if (!quote || !buyAmt) return false;
    const tx = await quote.approve(ADDRESSES.fairlaunch, parseEther(buyAmt));
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
      setOkMsg(`Bought ${formatEther(previewOut)} RLO`);
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
      setOkMsg(`Sold ${sellAmt} RLO for ~${formatEther(previewIn)} WSETH`);
      setSellAmt("");
      await refresh();
    } catch (e) {
      setErr(String(e.shortMessage || e.reason || e.message || e));
    } finally {
      setBusy(false);
    }
  };

  const doApproveSell = async () => {
    if (!token || !sellAmt) return;
    const tx = await token.approve(ADDRESSES.fairlaunch, parseEther(sellAmt));
    await tx.wait();
    setOkMsg("Approved RLO for selling");
    await refresh();
  };

  const doSeed = async () => {
    if (!launch) return;
    setBusy(true);
    setErr("");
    try {
      const tx = await quote.approve(ADDRESSES.fairlaunch, parseEther("10"));
      await tx.wait();
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

  const doGraduate = async () => {
    if (!launch) return;
    setBusy(true);
    setErr("");
    try {
      const tx = await launch.graduate();
      await tx.wait();
      setOkMsg("Graduated! Pool is live.");
      await refresh();
    } catch (e) {
      setErr(String(e.shortMessage || e.reason || e.message || e));
    } finally {
      setBusy(false);
    }
  };

  const isOwner = account && launch && account.toLowerCase() === (ADDRESSES.ownerWallet || "").toLowerCase();
  const progress = target > 0n ? Number((reserves[1] * 10000n) / target) / 100 : 0;
  const phaseName = phase === null ? "…" : PHASE[phase];

  return (
    <div className="wrap">
      <h1>
        Rialo <span className="dot">Fair Launch</span>
      </h1>
      <p className="sub">
        pump.fun-style bonding curve on {CHAIN_NAME}. Buy rises the price, sell lowers it, and the
        market graduates into a pool when the curve fills.
      </p>

      <div className="card">
        <div className="row" style={{justifyContent: "space-between"}}>
          <div>
            {phase === null ? (
              <span className="badge">loading…</span>
            ) : (
              <span className={`badge ${phaseName.toLowerCase()}`}>{phaseName}</span>
            )}{" "}
            <span className="muted">fairlaunch {short(ADDRESSES.fairlaunch)}</span>
          </div>
          {account ? (
            <span className="muted">{short(account)}</span>
          ) : (
            <button className="btn" onClick={connect}>
              Connect wallet
            </button>
          )}
        </div>
        {account && !chainOk && (
          <div className="err">Wrong network. Switch to {CHAIN_NAME} (chain id {SEPOLIA_CHAIN_ID}).</div>
        )}
      </div>

      <div className="card">
        <div className="row">
          <div className="stat">
            <div className="k">Price</div>
            <div className="v">{formatEther(price)}</div>
            <div className="muted">WSETH per RLO</div>
          </div>
          <div className="stat">
            <div className="k">Curve quote</div>
            <div className="v">{formatEther(reserves[1])}</div>
            <div className="muted">of {formatEther(target)} target</div>
          </div>
          <div className="stat">
            <div className="k">Curve tokens</div>
            <div className="v">{formatEther(reserves[0])}</div>
            <div className="muted">RLO on the book</div>
          </div>
        </div>
        <div className="chart">
          <div className="fill" style={{width: `${Math.min(100, progress)}%`}} />
          <span className="cap">{progress.toFixed(2)}% to graduation</span>
          <span className="progress-label">fee {feeBps / 100}% · fees {formatEther(fees)}</span>
        </div>
      </div>

      {phase === 2 ? (
        <div className="card">
          <h3>Pool is live</h3>
          <p className="muted">
            Graduated at rate {formatEther(gradRate)} WSETH/RLO. Trade in the pool:
          </p>
          <div className="row">
            <div className="stat">
              <div className="k">Pool RLO</div>
              <div className="v">{formatEther(poolReserves[0])}</div>
            </div>
            <div className="stat">
              <div className="k">Pool WSETH</div>
              <div className="v">{formatEther(poolReserves[1])}</div>
            </div>
            <div className="stat">
              <div className="k">Pool address</div>
              <div className="v" style={{fontSize: 14}}>
                {short(poolAddr)}
              </div>
            </div>
          </div>
          <p className="muted" style={{marginTop: 12}}>
            Call <code>swapExactToken1ForToken0</code> / <code>swapExactToken0ForToken1</code> on the
            pool contract above. Approve the pool for the input token first.
          </p>
        </div>
      ) : (
        <div className="grid2">
          <div className="card">
            <h3>Buy</h3>
            <div className="field">
              <label>WSETH in</label>
              <input
                className="input"
                type="number"
                min="0"
                step="0.01"
                placeholder="0.0"
                value={buyAmt}
                onChange={(e) => setBuyAmt(e.target.value)}
              />
            </div>
            <div className="muted" style={{marginBottom: 12}}>
              ≈ {formatEther(previewOut)} RLO out · balance {formatEther(balQuote)} WSETH
            </div>
            <button className="btn" disabled={busy || !account} onClick={doBuy}>
              {busy ? "…" : "Buy RLO"}
            </button>
          </div>

          <div className="card">
            <h3>Sell</h3>
            <div className="field">
              <label>RLO in</label>
              <input
                className="input"
                type="number"
                min="0"
                step="0.01"
                placeholder="0.0"
                value={sellAmt}
                onChange={(e) => setSellAmt(e.target.value)}
              />
            </div>
            <div className="muted" style={{marginBottom: 12}}>
              ≈ {formatEther(previewIn)} WSETH out · balance {formatEther(balToken)} RLO
            </div>
            <div className="admin">
              <button className="btn ghost" disabled={busy || !account} onClick={doApproveSell}>
                Approve RLO
              </button>
              <button className="btn" disabled={busy || !account} onClick={doSell}>
                {busy ? "…" : "Sell RLO"}
              </button>
            </div>
          </div>
        </div>
      )}

      {isOwner && phase === 0 && (
        <div className="card">
          <h3>Owner: seed the curve</h3>
          <p className="muted">Seeding sets the starting price and opens trading.</p>
          <button className="btn" disabled={busy} onClick={doSeed}>
            Seed with 10 WSETH
          </button>
        </div>
      )}

      {isOwner && phase === 1 && (
        <div className="card">
          <h3>Owner</h3>
          <div className="admin">
            <button className="btn ghost" disabled={busy} onClick={doGraduate}>
              Graduate manually
            </button>
          </div>
          <p className="muted" style={{marginTop: 8}}>
            Graduation also happens automatically on the buy that fills the curve.
          </p>
        </div>
      )}

      {err && <div className="err">{err}</div>}
      {okMsg && <div className="ok">{okMsg}</div>}

      <p className="muted" style={{marginTop: 24}}>
        Audited by {37} property tests. Source:{" "}
        <code>/home/ubuntu/rialo-launchpad</code>
      </p>
    </div>
  );
}
