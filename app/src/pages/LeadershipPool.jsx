import { useState } from "react";
import { ArrowLeft } from "lucide-react";
import { Link } from "react-router-dom";
import { useAccount, useReadContract, useReadContracts } from "wagmi";
import { CONTRACTS, REWARDS_ABI } from "../config/contracts.js";
import { ACTIVE_CHAIN_ID, BLOCK_TAG } from "../lib/appkit.js";
import { money } from "../lib/format.js";

const QUALIFIERS = 10;
const rewards = { address: CONTRACTS.rewards, abi: REWARDS_ABI, chainId: ACTIVE_CHAIN_ID };
const shortWallet = (wallet) => `${wallet.slice(0, 6)}…${wallet.slice(-4)}`;

/** A month key is year * 12 + month - 1. On testnet a month is a 30-minute period. */
function monthName(key) {
  if (ACTIVE_CHAIN_ID === 31337) return `Testnet period ${key}`;
  const date = new Date(Date.UTC(Math.floor(key / 12), key % 12, 1));
  return date.toLocaleDateString(undefined, { month: "long", year: "numeric", timeZone: "UTC" });
}

function Row({ rank, wallet, volume, share, you }) {
  const qualified = rank <= QUALIFIERS;
  return (
    <li className={`flex items-center gap-3 rounded-2xl px-3 py-2.5 ${qualified ? "bg-brand/10" : ""}`}>
      <span className={`grid size-7 shrink-0 place-items-center rounded-full text-[12px] font-extrabold ${qualified ? "bg-brand text-on-brand" : "bg-surface-2 text-muted"}`}>{rank}</span>
      <div className="min-w-0 flex-1">
        <p className="text-[13.5px] font-bold">{shortWallet(wallet)}{you && <span className="chip chip-soft ml-2 !h-5 !px-2 !text-[11px]">You</span>}</p>
        <p className="text-[12px] text-muted">{money(volume)} USDT volume</p>
      </div>
      {qualified && <p className="text-right text-[13px] font-extrabold">{money(share)} USDT</p>}
    </li>
  );
}

/** Each month's top 50 wallets by direct referral volume. Only the top 10 share the pool. */
export default function LeadershipPool() {
  const { address } = useAccount();
  const [back, setBack] = useState(0); // 0 = this month, 1 = last month

  const { data: current } = useReadContract({ ...rewards, functionName: "currentMonth", blockTag: BLOCK_TAG, query: { refetchInterval: 15_000 } });
  const month = current === undefined ? undefined : current - BigInt(back);

  const { data: list, isLoading } = useReadContracts({
    contracts: [
      { ...rewards, functionName: "monthLeaders", args: [month] },
      { ...rewards, functionName: "monthPool", args: [month] },
    ],
    allowFailure: false,
    blockTag: BLOCK_TAG,
    query: { enabled: month !== undefined, refetchInterval: 15_000 },
  });
  const [leaders, pool] = list ?? [];

  const { data: volumes } = useReadContracts({
    contracts: (leaders ?? []).map((wallet) => ({ ...rewards, functionName: "monthVolume", args: [month, wallet] })),
    allowFailure: false,
    blockTag: BLOCK_TAG,
    query: { enabled: Boolean(leaders?.length) },
  });

  const ready = leaders !== undefined && (leaders.length === 0 || volumes !== undefined);
  const topVolume = (volumes ?? []).slice(0, QUALIFIERS).reduce((sum, v) => sum + v, 0n);
  const share = (volume) => (topVolume === 0n ? 0n : (pool * volume) / topVolume);
  const rank = address ? (leaders ?? []).findIndex((w) => w.toLowerCase() === address.toLowerCase()) + 1 : 0;

  return (
    <section className="section">
      <Link to="/rewards" className="mb-3 inline-flex items-center gap-1 text-[13px] font-semibold text-brand"><ArrowLeft className="size-4" />Rewards</Link>

      <div className="tabs-pills mb-3">
        {["This month", "Last month"].map((label, i) => (
          <button key={label} type="button" className={back === i ? "is-active" : ""} aria-pressed={back === i} onClick={() => setBack(i)}>{label}</button>
        ))}
      </div>

      <div className="card card-gradient shape-bubbles p-5">
        <p className="text-[13px] font-semibold text-white/80">{month === undefined ? "…" : monthName(Number(month))}</p>
        <p className="mt-1 text-[30px] font-extrabold leading-none">{money(pool)} <span className="text-base font-bold">USDT pool</span></p>
        <p className="mt-3 text-[12.5px] text-white/80">
          {back === 0 ? (ACTIVE_CHAIN_ID === 31337 ? "Ranks and shares can change until this 30-minute period ends." : "Ranks and shares can change until 00:00 UTC on the 1st.") : "This month has closed. Shares are final."}
        </p>
      </div>

      <div className="section-head mt-5"><div>
        <h2 className="section-title">Top 50 wallets</h2>
        <p className="section-sub">The top {QUALIFIERS} share the pool by direct referral volume.{rank > 0 && ` You're ranked ${rank}.`}</p>
      </div></div>

      {!ready || isLoading
        ? <p className="py-6 text-center text-[13px] text-muted">Loading the leaderboard…</p>
        : leaders.length === 0
          ? <div className="card card-body text-center"><p className="text-[13px] text-muted">No wallets qualify for this month yet.</p></div>
          : (
            <ol className="card space-y-1 p-2">
              {leaders.map((wallet, i) => (
                <Row key={wallet} rank={i + 1} wallet={wallet} volume={volumes[i]} share={share(volumes[i])} you={i + 1 === rank} />
              ))}
            </ol>
          )}
    </section>
  );
}
