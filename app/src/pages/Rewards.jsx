import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { useQueryClient } from "@tanstack/react-query";
import { useAccount, useReadContracts } from "wagmi";
import { useUi } from "../components/Ui.jsx";
import { CONTRACTS, GATEWAY_ABI, REWARDS_ABI } from "../config/contracts.js";
import { ACTIVE_CHAIN_ID, BLOCK_TAG } from "../lib/appkit.js";
import { money } from "../lib/format.js";
import { reason, send } from "../lib/tx.js";

const TIERS = [50, 100, 200, 400, 800, 1600];
const LAST = TIERS.length - 1;
const rewards = { address: CONTRACTS.rewards, abi: REWARDS_ABI, chainId: ACTIVE_CHAIN_ID };
const gateway = { address: CONTRACTS.gateway, abi: GATEWAY_ABI, chainId: ACTIVE_CHAIN_ID };

function secondsLeft(until) {
  return Math.max(0, Math.ceil(Number(until) - Date.now() / 1000));
}

function waitLabel(seconds) {
  if (seconds < 90) return `${seconds}s`;
  if (seconds < 5400) return `${Math.ceil(seconds / 60)}m`;
  return `${Math.ceil(seconds / 3600)}h`;
}

function ClaimRow({ title, note, extra, amount, label, disabled, busy, onClaim }) {
  return (
    <div className="flex items-center gap-3 py-3 first:pt-0 last:pb-0">
      <div className="min-w-0 flex-1">
        <p className="text-[14px] font-bold">{title}</p>
        <p className="text-[12px] text-muted">{note}</p>
        {extra}
      </div>
      <div className="text-right">
        <p className="text-[14px] font-extrabold">{money(amount)} USDT</p>
        <button type="button" className="btn btn-primary btn-sm mt-1" disabled={disabled || busy} onClick={onClaim}>{busy ? "Confirm…" : label}</button>
      </div>
    </div>
  );
}

function tierState(tier, next, capping, unlocked) {
  if (tier < next) {
    if (capping > 0n) return "active";
    return tier === LAST ? "ready" : "capped";
  }
  if (tier > next) return "later";
  return unlocked ? "ready" : "locked";
}

const STATE_TEXT = {
  capped: "Capped",
  later: "Activate the tier before this one first",
  locked: "Opens with time, or when the previous two tiers cap",
};

function TierRow({ tier, state, capping, wallet, busy, disabled, onActivate }) {
  const price = BigInt(TIERS[tier]) * 10n ** 18n;
  const again = state === "ready" && tier === LAST && capping === 0n;
  return (
    <div className="flex items-center gap-3 py-3 first:pt-0 last:pb-0">
      <div className="min-w-0 flex-1">
        <p className="text-[14px] font-bold">${TIERS[tier].toLocaleString()}</p>
        <p className="text-[12px] text-muted">
          {state === "active" ? `${money(capping)} USDT capping left` : state === "ready" ? `${money(price * 3n)} USDT capping` : STATE_TEXT[state]}
        </p>
      </div>
      {state === "active" && <span className="chip chip-soft">Active</span>}
      {state === "ready" && (
        <button type="button" className="btn btn-primary btn-sm" disabled={disabled || busy || wallet < price} onClick={() => onActivate(tier)}>
          {busy ? "Confirm…" : again ? "Activate again" : "Activate"}
        </button>
      )}
    </div>
  );
}

/** Activate tiers and collect the daily, generation and leadership rewards. */
export default function Rewards() {
  const { address } = useAccount();
  const { toast } = useUi();
  const queryClient = useQueryClient();
  const [pending, setPending] = useState("");
  const [error, setError] = useState("");
  const [, setTick] = useState(0);

  // Re-render every second so the countdowns move even when the chain data hasn't changed.
  useEffect(() => {
    const id = setInterval(() => setTick((t) => t + 1), 1000);
    return () => clearInterval(id);
  }, []);

  const { data, isLoading, isError } = useReadContracts({
    contracts: [
      { ...rewards, functionName: "getUser", args: [address] },
      { ...rewards, functionName: "nextTier", args: [address] },
      { ...gateway, functionName: "coolDown", args: [address] },
      { ...rewards, functionName: "DAY" },
      ...TIERS.map((_, tier) => ({ ...rewards, functionName: "tierCapping", args: [address, tier] })),
      ...TIERS.map((_, tier) => ({ ...rewards, functionName: "isTierUnlocked", args: [address, tier] })),
    ],
    allowFailure: false,
    blockTag: BLOCK_TAG,
    query: { enabled: Boolean(address), refetchInterval: ACTIVE_CHAIN_ID === 31337 ? 5_000 : 15_000 },
  });

  const run = async (key, functionName, args, done, target = rewards) => {
    setPending(key);
    setError("");
    try {
      await send({ ...target, functionName, args }, address);
      await queryClient.invalidateQueries();
      toast(done);
    } catch (err) {
      setError(reason(err));
    }
    setPending("");
  };

  if (isError) return <section className="section"><div className="card card-body text-center"><p className="text-[13px] text-muted">We couldn't load your rewards. Check your connection and try again.</p></div></section>;
  if (isLoading || !data) return <section className="section"><p className="text-center text-[13px] text-muted">Loading your rewards…</p></section>;

  const [user, nextTier, coolDown, day, ...rest] = data;
  const cappings = rest.slice(0, TIERS.length);
  const unlocked = rest.slice(TIERS.length);
  const next = Number(nextTier);
  const wait = secondsLeft(user.nextClaim);
  const agentWait = secondsLeft(coolDown);
  const busy = Boolean(pending);

  return (
    <>
      <section className="section">
        <div className="card grid grid-cols-2 divide-x divide-line py-4 text-center">
          <div><p className="text-xl font-extrabold">{money(user.walletBalance)}</p><p className="text-[11.5px] font-semibold text-muted">Wallet balance</p></div>
          <div><p className="text-xl font-extrabold">{money(user.capping)}</p><p className="text-[11.5px] font-semibold text-muted">Capping left</p></div>
        </div>
        {error && <p className="mt-3 text-center text-[12.5px] font-semibold text-rose-500" role="alert">{error}</p>}
      </section>

      <section className="section">
        <div className="section-head"><div>
          <h2 className="section-title">Collect</h2>
          <p className="section-sub">Daily, generation and leadership go to your wallet balance.</p>
        </div></div>
        <div className="card card-body divide-y divide-line">
          <ClaimRow
            title="Daily 1%"
            note={wait > 0 ? `Next claim in about ${waitLabel(wait)}` : day === 86400n ? "Once every 24 hours" : "Once every 60 seconds on testnet"}
            amount={user.pendingDaily}
            label="Collect"
            disabled={busy || user.pendingDaily === 0n || wait > 0}
            busy={pending === "daily"}
            onClaim={() => run("daily", "claimDaily", [], "Daily rewards collected.")}
          />
          <ClaimRow
            title="Generation bonus"
            note="From your 10 sponsor levels"
            amount={user.generationBalance}
            label="Collect"
            disabled={busy || user.generationBalance === 0n}
            busy={pending === "generation"}
            onClaim={() => run("generation", "claimGeneration", [], "Generation bonus collected.")}
          />
          <ClaimRow
            title="Leadership pool"
            note="Your share of finished months"
            extra={<Link to="/rewards/leadershippool" className="text-[12px] font-semibold text-brand">View leaderboard</Link>}
            amount={user.pendingLeadership}
            label="Collect"
            disabled={busy || user.pendingLeadership === 0n}
            busy={pending === "leadership"}
            onClaim={() => run("leadership", "claimLeadership", [], "Leadership rewards collected.")}
          />
          {user.isAgent && (
            <ClaimRow
              title="Agent rewards"
              note={agentWait > 0 ? `Cooldown ends in about ${waitLabel(agentWait)}` : "Paid to your connected wallet, no fee"}
              amount={user.agentBalance}
              label="Collect"
              disabled={busy || user.agentBalance === 0n || agentWait > 0}
              busy={pending === "agent"}
              onClaim={() => run("agent", "withdrawAgent", [user.agentBalance], "Agent rewards sent to your wallet.", gateway)}
            />
          )}
        </div>
      </section>

      <section className="section">
        <div className="section-head"><div>
          <h2 className="section-title">Activate tiers</h2>
          <p className="section-sub">Paid from your wallet balance, in order. Each tier gives 3x capping.</p>
        </div></div>
        <div className="card card-body divide-y divide-line">
          {TIERS.map((_, tier) => (
            <TierRow
              key={tier}
              tier={tier}
              state={tierState(tier, next, cappings[tier], unlocked[tier])}
              capping={cappings[tier]}
              wallet={user.walletBalance}
              busy={pending === `tier-${tier}`}
              disabled={busy}
              onActivate={(t) => run(`tier-${t}`, "activate", [BigInt(t)], `$${TIERS[t].toLocaleString()} tier activated.`)}
            />
          ))}
        </div>
      </section>
    </>
  );
}
