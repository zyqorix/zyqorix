import { useEffect, useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { erc20Abi } from "viem";
import { useAccount, useReadContracts } from "wagmi";
import { useUi } from "../components/Ui.jsx";
import vestingAbi from "../config/abi/vesting.json";
import { CONTRACTS } from "../config/contracts.js";
import { ACTIVE_CHAIN_ID, BLOCK_TAG } from "../lib/appkit.js";
import { money } from "../lib/format.js";
import { reason, send } from "../lib/tx.js";

const vesting = { address: CONTRACTS.vesting, abi: vestingAbi, chainId: ACTIVE_CHAIN_ID };
const refetchInterval = ACTIVE_CHAIN_ID === 31337 ? 5_000 : 15_000;

function waitLabel(seconds) {
  if (seconds < 90) return `${seconds}s`;
  if (seconds < 5400) return `${Math.ceil(seconds / 60)}m`;
  if (seconds < 172800) return `${Math.ceil(seconds / 3600)}h`;
  return `${Math.ceil(seconds / 86400)}d`;
}

const date = (ts) => new Date(Number(ts) * 1000).toLocaleDateString(undefined, { year: "numeric", month: "short", day: "numeric" });

/** Months matured and the next unlock time for one position, on the local clock (anvil's block time lags). */
function schedule(p, month) {
  const now = Math.floor(Date.now() / 1000);
  const start = Number(p.startTime);
  const months = Number(p.months);
  const matured = Math.min(months, Math.floor(Math.max(0, now - start) / month));
  const next = matured < months ? start + (matured + 1) * month : 0;
  return { matured, months, next, wait: next ? Math.max(0, next - now) : 0 };
}

function PositionRow({ index, p, month }) {
  const { matured, months, wait } = schedule(p, month);
  const pct = Number((p.totalClaim * 1000n) / (p.amount || 1n)) / 10;
  return (
    <div className="border-b border-line py-3 first:pt-0 last:border-0 last:pb-0">
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <p className="text-[14px] font-bold">Position {index + 1}</p>
          <p className="text-[12px] text-muted">Started {date(p.startTime)} · {money(p.monthlyClaim)} ZQR a month</p>
        </div>
        {p.expired ? <span className="chip chip-soft">Complete</span> : <span className="chip chip-soft">{matured} of {months} months</span>}
      </div>
      <div className="mt-2 h-1.5 overflow-hidden rounded-full bg-line">
        <div className="h-full rounded-full bg-brand" style={{ width: `${pct}%` }} />
      </div>
      <div className="mt-1.5 flex justify-between text-[11.5px] text-muted">
        <span>{money(p.totalClaim)} of {money(p.amount)} ZQR claimed</span>
        {!p.expired && matured < months && <span>Next month in {waitLabel(wait)}</span>}
      </div>
    </div>
  );
}

/** The member's ZQR vesting: one position per activation, released monthly, claimed together. */
export default function Vesting() {
  const { address } = useAccount();
  const { toast } = useUi();
  const queryClient = useQueryClient();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [, setTick] = useState(0);

  // Re-render every second so the countdowns move even when the chain data hasn't changed.
  useEffect(() => {
    const id = setInterval(() => setTick((t) => t + 1), 1000);
    return () => clearInterval(id);
  }, []);

  const head = useReadContracts({
    contracts: [
      { ...vesting, functionName: "positionCount", args: [address] },
      { ...vesting, functionName: "claimable", args: [address] },
      { ...vesting, functionName: "MONTH" },
      { address: CONTRACTS.zqr, abi: erc20Abi, functionName: "balanceOf", args: [address], chainId: ACTIVE_CHAIN_ID },
    ],
    allowFailure: false,
    blockTag: BLOCK_TAG,
    query: { enabled: Boolean(address && CONTRACTS.vesting), refetchInterval },
  });
  const [count, claimable, month, zqrBalance] = head.data ?? [];

  const list = useReadContracts({
    contracts: Array.from({ length: Number(count ?? 0) }, (_, i) => ({ ...vesting, functionName: "getPosition", args: [address, BigInt(i)] })),
    allowFailure: false,
    blockTag: BLOCK_TAG,
    query: { enabled: Number(count ?? 0) > 0, refetchInterval },
  });
  const positions = list.data ?? [];

  const due = claimable ?? 0n;

  const claim = async () => {
    setBusy(true);
    setError("");
    try {
      await send({ ...vesting, functionName: "claim" }, address);
      await queryClient.invalidateQueries();
      toast("Vested ZQR claimed.");
    } catch (err) {
      setError(reason(err));
    }
    setBusy(false);
  };

  if (!CONTRACTS.vesting) return <section className="section"><div className="card card-body text-center"><p className="text-[13px] text-muted">Vesting isn't available on this network yet.</p></div></section>;
  if (head.isError) return <section className="section"><div className="card card-body text-center"><p className="text-[13px] text-muted">We couldn't load your vesting. Check your connection and try again.</p></div></section>;
  if (head.isLoading || !head.data) return <section className="section"><p className="text-center text-[13px] text-muted">Loading your vesting…</p></section>;

  const granted = positions.reduce((s, p) => s + p.amount, 0n);
  const claimed = positions.reduce((s, p) => s + p.totalClaim, 0n);
  const m = Number(month);
  const waits = positions.filter((p) => !p.expired).map((p) => schedule(p, m)).filter((s) => s.next).map((s) => s.wait);
  const nextWait = waits.length ? Math.min(...waits) : null;

  return (
    <>
      <section className="section">
        <div className="section-head"><div>
          <h2 className="section-title">Vesting</h2>
          <p className="section-sub">Each activation grants ZQR at the token price, released over {positions[0] ? Number(positions[0].months) : 60} monthly unlocks.</p>
        </div></div>
        <div className="card card-body text-center">
          <p className="text-[11.5px] font-semibold uppercase tracking-wide text-muted">Ready to claim</p>
          <p className="mt-1 text-3xl font-extrabold">{money(due)} <span className="text-[15px] font-bold text-muted">ZQR</span></p>
          <p className="mt-1 text-[12px] text-muted">{nextWait === null ? (positions.length ? "Every position is fully released." : "No positions yet.") : `Next unlock in ${waitLabel(nextWait)}`}</p>
          <button type="button" className="btn btn-primary mt-4 w-full" disabled={busy || due === 0n} onClick={claim}>{busy ? "Confirm…" : "Claim"}</button>
          {error && <p className="mt-3 text-[12.5px] font-semibold text-rose-500" role="alert">{error}</p>}
        </div>
      </section>

      <section className="section pt-0">
        <div className="card grid grid-cols-3 divide-x divide-line py-4 text-center">
          <div><p className="text-lg font-extrabold">{money(granted)}</p><p className="text-[11px] font-semibold text-muted">Granted</p></div>
          <div><p className="text-lg font-extrabold">{money(claimed)}</p><p className="text-[11px] font-semibold text-muted">Claimed</p></div>
          <div><p className="text-lg font-extrabold">{money(zqrBalance)}</p><p className="text-[11px] font-semibold text-muted">In your wallet</p></div>
        </div>
      </section>

      <section className="section pt-0">
        <div className="section-head"><div><h2 className="section-title">Positions</h2></div></div>
        <div className="card card-body">
          {positions.length === 0
            ? <p className="text-center text-[13px] text-muted">Activate a tier on Rewards to start vesting ZQR.</p>
            : positions.map((p, i) => <PositionRow key={i} index={i} p={p} month={m} />)}
        </div>
      </section>
    </>
  );
}
