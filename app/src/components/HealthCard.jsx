import { useState } from "react";
import { HeartPulse, RefreshCw } from "lucide-react";
import { Link } from "react-router-dom";
import { useQueryClient } from "@tanstack/react-query";
import { erc20Abi, formatUnits, parseUnits } from "viem";
import { useAccount, useReadContracts } from "wagmi";
import funderAbi from "../config/abi/funder.json";
import rewardsAbi from "../config/abi/rewards.json";
import { CONTRACTS } from "../config/contracts.js";
import { ACTIVE_CHAIN_ID, BLOCK_TAG } from "../lib/appkit.js";
import { money } from "../lib/format.js";
import { ensureAllowance, reason, send } from "../lib/tx.js";
import { FundingWallets } from "./FundingWallets.jsx";

const rewards = { address: CONTRACTS.rewards, abi: rewardsAbi, chainId: ACTIVE_CHAIN_ID };
const funder = { address: CONTRACTS.funder, abi: funderAbi, chainId: ACTIVE_CHAIN_ID };
const usdt = { address: CONTRACTS.usdt, abi: erc20Abi, chainId: ACTIVE_CHAIN_ID };

function Row({ label, value, note, tone = "" }) {
  return (
    <div className="flex items-start justify-between gap-3 border-b border-line py-2 last:border-0">
      <div className="min-w-0">
        <p className="text-[13px] font-semibold">{label}</p>
        {note && <p className="text-[11.5px] text-muted">{note}</p>}
      </div>
      <p className={`shrink-0 text-right text-[13px] font-extrabold ${tone}`}>{value}</p>
    </div>
  );
}

/** Admin health balance: what members can ask to withdraw against what the funder holds, and the reward pool
 *  against the daily and generation rewards waiting on it. Funding goes through funder.fundRewards. */
export default function HealthCard() {
  const { address } = useAccount();
  const queryClient = useQueryClient();
  const [amount, setAmount] = useState("");
  const [step, setStep] = useState("");
  const [error, setError] = useState("");

  const { data, isLoading, refetch } = useReadContracts({
    contracts: [
      { ...rewards, functionName: "totalWalletBalance" },
      { ...rewards, functionName: "totalAgentBalance" },
      { ...rewards, functionName: "totalRewardCredit" },
      { ...funder, functionName: "rewardPool" },
      { ...funder, functionName: "tradingCapitalOut" },
      { ...usdt, functionName: "balanceOf", args: [CONTRACTS.funder] },
      { ...usdt, functionName: "balanceOf", args: [address] },
      { ...usdt, functionName: "allowance", args: [address, CONTRACTS.funder] },
      { ...funder, functionName: "pendingFunding" },
    ],
    blockTag: BLOCK_TAG,
    query: { enabled: Boolean(CONTRACTS.funder && CONTRACTS.rewards && address), refetchInterval: 15_000 },
  });
  const value = (i) => (data?.[i]?.status === "success" ? data[i].result : undefined);
  const [wallets, agents, credit, pool, sentToTrading, held, mine, allowance, pending] = data ? data.map((_, i) => value(i)) : [];

  // Contracts before 2026-11-04 don't keep these totals: show the rows that can be read.
  const tracked = wallets !== undefined && agents !== undefined;
  const liabilities = tracked ? wallets + agents : undefined;
  const coverage = tracked && held !== undefined ? held - liabilities : undefined;
  const poolGap = credit !== undefined && pool !== undefined && credit > pool ? credit - pool : 0n;
  // The first withdrawal the pool can't cover pulls every funding wallet's approved USDT into the pool,
  // so only the part those wallets can't cover still needs funding.
  const waiting = pending ?? 0n;
  const neededForPool = poolGap > waiting ? poolGap - waiting : 0n;
  const coverageGap = coverage !== undefined && coverage < 0n ? -coverage : 0n;
  const suggested = neededForPool > coverageGap ? neededForPool : coverageGap;

  let parsed = 0n;
  try { parsed = amount ? parseUnits(amount, 18) : 0n; } catch { parsed = 0n; }
  const ready = parsed > 0n && mine !== undefined && parsed <= mine && !step;

  const fund = async () => {
    if (!ready) return;
    setError("");
    try {
      setStep("Approve USDT…");
      await ensureAllowance(CONTRACTS.usdt, CONTRACTS.funder, parsed, address);
      setStep("Confirm the funding…");
      await send({ ...funder, functionName: "fundRewards", args: [parsed] }, address);
      await queryClient.invalidateQueries();
      setAmount("");
    } catch (err) {
      setError(reason(err));
    }
    setStep("");
  };

  return (
    <section className="section">
      <div className="section-head">
        <div>
          <h2 className="section-title flex items-center gap-2"><HeartPulse className="size-4 text-rose-500" />Health</h2>
          <p className="section-sub">{isLoading ? "Reading the contracts…" : "What members can withdraw, against what the funder holds."}</p>
        </div>
        <button type="button" className="btn btn-ghost btn-xs" onClick={() => refetch()}><RefreshCw className="size-3.5" />Refresh</button>
      </div>
      <div className="card card-body">
        <Row label="Wallet balances" note="Every member's wallet balance, ready to withdraw" value={tracked ? `${money(wallets)} USDT` : "—"} />
        <Row label="Agent balances" value={tracked ? `${money(agents)} USDT` : "—"} />
        <Row label="Total liabilities" value={liabilities !== undefined ? `${money(liabilities)} USDT` : "—"} />
        <Row label="Funder USDT" value={held !== undefined ? `${money(held)} USDT` : "—"} />
        <Row
          label="Coverage"
          note={coverage === undefined ? "Available after the new rewards deploy" : coverage < 0n ? "The funder holds less than members can withdraw" : "The funder holds every liability"}
          value={coverage === undefined ? "—" : coverage < 0n ? `−${money(-coverage)} USDT` : `+${money(coverage)} USDT`}
          tone={coverage === undefined ? "" : coverage < 0n ? "text-rose-500" : "text-emerald-500"}
        />
        <Row label="Daily and generation credit" note="Part of the wallet balances, paid only from the reward pool" value={credit !== undefined ? `${money(credit)} USDT` : "—"} />
        <Row label="Reward pool" value={pool !== undefined ? `${money(pool)} USDT` : "—"} />
        <Row
          label="Waiting in funding wallets"
          note="Approved USDT the next withdrawal the pool can't cover pulls in"
          value={pending !== undefined ? `${money(pending)} USDT` : "—"}
        />
        <Row
          label="Pool shortfall"
          note={
            neededForPool > 0n
              ? "Fund the pool or top up a funding wallet: members can't withdraw this part yet"
              : poolGap > 0n
                ? `${money(poolGap)} USDT short, covered by the funding wallets: pulled in on the next withdrawal`
                : undefined
          }
          value={credit === undefined ? "—" : `${money(neededForPool)} USDT`}
          tone={neededForPool > 0n ? "text-rose-500" : poolGap > 0n ? "text-amber-500" : "text-emerald-500"}
        />
        {sentToTrading !== undefined && <Row label="Sent to trading" note="Activation shares spent on trading; only the profit comes back" value={`${money(sentToTrading)} USDT`} />}
      </div>

      <div className="card card-body mt-3">
        <p className="text-[13px] font-bold">Fund the reward pool</p>
        <p className="mt-1 text-[12px] text-muted">
          Sends trading profit from your wallet with funder.fundRewards. All of it enters the reward pool. A plain transfer to the funder does not count.
        </p>
        <div className="mt-3 flex gap-2">
          <input className="input input-filled flex-1" inputMode="decimal" placeholder="Amount (USDT)" value={amount} disabled={Boolean(step)}
            onChange={(e) => { setAmount(e.target.value.replace(/[^0-9.]/g, "")); setError(""); }} />
          {suggested > 0n && (
            <button type="button" className="btn btn-neutral btn-sm" disabled={Boolean(step)} onClick={() => setAmount(formatUnits(suggested, 18))}>Shortfall</button>
          )}
        </div>
        {mine !== undefined && <p className="mt-2 text-[12px] text-muted">Your USDT: {money(mine)}</p>}
        {error && <p className="mt-2 text-[12.5px] font-semibold text-rose-500" role="alert">{error}</p>}
        <button type="button" className="btn btn-primary btn-block mt-3" disabled={!ready} onClick={fund}>{step || "Fund"}</button>
        <Link to="/admin/funder" className="mt-2 block text-center text-[12px] font-semibold text-brand">Open the funder contract</Link>
      </div>

      <FundingWallets />
    </section>
  );
}
