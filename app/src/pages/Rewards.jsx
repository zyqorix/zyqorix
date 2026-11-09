import { useEffect, useState } from "react";
import { BadgeCheck } from "lucide-react";
import { Link } from "react-router-dom";
import { useQueryClient } from "@tanstack/react-query";
import { useAccount, useReadContract, useReadContracts } from "wagmi";
import { useUi } from "../components/Ui.jsx";
import { CONTRACTS, FUNDER_ABI, GATEWAY_ABI, REWARDS_ABI } from "../config/contracts.js";
import { ACTIVE_CHAIN_ID, BLOCK_TAG } from "../lib/appkit.js";
import { money } from "../lib/format.js";
import { reason, send } from "../lib/tx.js";

const TIERS = [50, 100, 200, 400, 800, 1600];
const LAST = TIERS.length - 1;
const rewards = { address: CONTRACTS.rewards, abi: REWARDS_ABI, chainId: ACTIVE_CHAIN_ID };
const gateway = { address: CONTRACTS.gateway, abi: GATEWAY_ABI, chainId: ACTIVE_CHAIN_ID };
// rewards.isTierUnlocked: each pair after the first opens UNLOCK_DAYS × pair days after the first activation, or earlier
// once both tiers of the pair before it have capped.
const UNLOCK_DAYS = 60;

function secondsLeft(until) {
  return Math.max(0, Math.ceil(Number(until) - Date.now() / 1000));
}

function waitLabel(seconds) {
  if (seconds < 90) return `${seconds}s`;
  if (seconds < 5400) return `${Math.ceil(seconds / 60)}m`;
  return `${Math.ceil(seconds / 3600)}h`;
}

/** A live timer: "12d 04:20:09", or "04:20:09" under a day. The page re-renders every second, so it ticks. */
function countdown(seconds) {
  const s = Math.max(0, Math.floor(seconds));
  const d = Math.floor(s / 86400);
  const clock = [Math.floor((s % 86400) / 3600), Math.floor((s % 3600) / 60), s % 60].map((n) => String(n).padStart(2, "0")).join(":");
  return d > 0 ? `${d}d ${clock}` : clock;
}

const pairName = (pair) => `$${TIERS[pair * 2].toLocaleString()} and $${TIERS[pair * 2 + 1].toLocaleString()}`;

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

/** Tiers not activated yet, after the first pair: the day their pair opens, counting down until then. */
function unlockText(tier, state, opensAt, unlocked) {
  const pair = Math.floor(tier / 2);
  if (pair === 0 || opensAt === undefined || state === "active" || state === "capped") return null;
  const openDay = pair * UNLOCK_DAYS;
  const left = secondsLeft(opensAt);
  if (left === 0 || unlocked) return null; // open: the Activate button takes over
  const date = new Date(Number(opensAt) * 1000).toLocaleString(undefined, { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" });
  return `Opens on day ${openDay}: in ${countdown(left)} (${date}), or sooner once ${pairName(pair - 1)} both reach zero capping`;
}

/** Days since the first activation, against the next day that opens a tier pair. */
function DayCounter({ start, day }) {
  const elapsed = Math.max(0, Date.now() / 1000 - Number(start));
  const today = Math.floor(elapsed / Number(day));
  const target = [UNLOCK_DAYS, UNLOCK_DAYS * 2].find((d) => today < d);
  const from = target === UNLOCK_DAYS * 2 ? UNLOCK_DAYS : 0;
  const pct = target ? Math.min(100, ((elapsed / Number(day) - from) / (target - from)) * 100) : 100;
  return (
    <div className="pb-3">
      <div className="flex items-baseline justify-between">
        <p className="text-[14px] font-bold">Day {today.toLocaleString()} since your first activation</p>
        <p className="text-[12px] text-muted">{target ? `Next: day ${target}` : "Every tier is open by time"}</p>
      </div>
      <div className="progress mt-2"><span style={{ width: `${pct}%` }} /></div>
      <p className="mt-1.5 text-[12px] text-muted">$200 and $400 open on day {UNLOCK_DAYS}, $800 and $1,600 on day {UNLOCK_DAYS * 2}, or sooner once the pair before has capped.</p>
    </div>
  );
}

function TierRow({ tier, state, capping, capBps, wallet, busy, disabled, onActivate, opensAt, unlocked, poolNeed, poolHas }) {
  const unlock = unlockText(tier, state, opensAt, unlocked);
  const price = BigInt(TIERS[tier]) * 10n ** 18n;
  // The rewards part of the price needs the reward pool to back its trading and liquidity shares (80% of it).
  const waitsForPool = state === "ready" && wallet >= price && poolNeed !== undefined && poolHas !== undefined && poolNeed > poolHas;
  const total = (price * capBps) / 10_000n;
  // Share of this tier's capping already earned; the bar fills as the tier works toward its cap.
  const earned = state === "active" && total > 0n ? Number(((total - (capping < total ? capping : total)) * 10_000n) / total) / 100 : 0;
  const again = state === "ready" && tier === LAST && capping === 0n;
  return (
    <div className="flex items-center gap-3 py-3 first:pt-0 last:pb-0">
      <div className="min-w-0 flex-1">
        <p className="text-[14px] font-bold">${TIERS[tier].toLocaleString()}</p>
        <p className="text-[12px] text-muted">
          {state === "active" ? `${money(capping)} of ${money(total)} USDT capping left` : state === "ready" || (state === "locked" && unlock) ? `${money(total)} USDT capping` : STATE_TEXT[state]}
        </p>
        {state === "active" && (
          <>
            <div className="progress mt-1.5"><span style={{ width: `${earned}%` }} /></div>
            <p className="mt-1 text-[11.5px] text-muted">{earned.toFixed(earned < 10 ? 1 : 0)}% earned</p>
          </>
        )}
        {unlock && <p className="text-[12px] font-semibold tabular-nums text-brand">{unlock}</p>}
        {waitsForPool && (
          <p className="text-[12px] font-semibold text-amber-600">
            Your rewards cover this tier, but the reward pool needs {money(poolNeed - poolHas)} USDT more. Try again after funding, or deposit to activate now.
          </p>
        )}
      </div>
      {state === "active" && <span className="chip chip-soft">Active</span>}
      {state === "locked" && <button type="button" className="btn btn-primary btn-sm" disabled>Activate</button>}
      {state === "ready" && (
        <button type="button" className="btn btn-primary btn-sm" disabled={disabled || busy || wallet < price || waitsForPool} onClick={() => onActivate(tier)}>
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
      { ...rewards, functionName: "unclaimedDaily", args: [address] },
      ...TIERS.map((_, tier) => ({ ...rewards, functionName: "tierCapping", args: [address, tier] })),
      ...TIERS.map((_, tier) => ({ ...rewards, functionName: "isTierUnlocked", args: [address, tier] })),
    ],
    allowFailure: false,
    blockTag: BLOCK_TAG,
    query: { enabled: Boolean(address), refetchInterval: ACTIVE_CHAIN_ID === 31337 ? 5_000 : 15_000 },
  });

  // The $1,600 tier's capping rate. Contracts deployed before capBps existed give 3x, so a failed read means 3x.
  const { data: capRead } = useReadContract({ ...rewards, functionName: "capBps", args: [BigInt(LAST)], query: { retry: false } });
  const lastCapBps = capRead ?? 30_000n;
  // Daily and generation are reward credit: they leave the wallet (withdraw or activate) only through the funded
  // reward pool. Contracts before 2026-11-04 have no rewardCredit, so a failed read hides the pool line.
  const { data: credit } = useReadContract({ ...rewards, functionName: "rewardCredit", args: [address], query: { enabled: Boolean(address), retry: false, refetchInterval: 15_000 } });
  // When the member first activated. Contracts before 2026-11-05 don't store it, so a failed read hides the count.
  const { data: firstActivation } = useReadContract({ ...rewards, functionName: "firstActivation", args: [address], query: { enabled: Boolean(address), retry: false } });
  const { data: pool } = useReadContract({ address: CONTRACTS.funder, abi: FUNDER_ABI, functionName: "rewardPool", chainId: ACTIVE_CHAIN_ID, query: { retry: false, refetchInterval: 15_000 } });
  // Funding-wallet USDT the funder pulls in by itself when an activation finds the pool short.
  const { data: waiting } = useReadContract({ address: CONTRACTS.funder, abi: FUNDER_ABI, functionName: "pendingFunding", chainId: ACTIVE_CHAIN_ID, query: { retry: false, refetchInterval: 15_000 } });
  // What the next tier would draw from the reward pool. Contracts before 2026-11-08 lack it, so a failed read
  // leaves the button as it was. The tier read is the last one, which reopens.
  const { data: readyTier } = useReadContract({ ...rewards, functionName: "nextTier", args: [address], query: { enabled: Boolean(address), retry: false } });
  const needTier = readyTier === undefined ? undefined : readyTier < BigInt(LAST) ? readyTier : BigInt(LAST);
  const { data: poolNeed } = useReadContract({ ...rewards, functionName: "activationPoolNeed", args: [address, needTier], query: { enabled: Boolean(address) && needTier !== undefined, retry: false, refetchInterval: 15_000 } });

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

  const [user, nextTier, coolDown, day, unclaimedDaily, ...rest] = data;
  const cappings = rest.slice(0, TIERS.length);
  const unlocked = rest.slice(TIERS.length);
  // Stored capping hasn't settled the days earned since the last sync yet; those already belong to the daily row.
  const accrued = user.pendingDaily > unclaimedDaily ? user.pendingDaily - unclaimedDaily : 0n;
  const cappingLeft = user.capping > accrued ? user.capping - accrued : 0n;
  const hasTiers = nextTier > 0n; // has activated at least once, so a zero means used up rather than never started
  const usedUp = hasTiers && cappingLeft === 0n;
  const poolShort = credit !== undefined && pool !== undefined && credit > pool;
  const poolHas = pool === undefined ? undefined : pool + (waiting ?? 0n);
  const deposited = credit !== undefined && user.walletBalance > credit ? user.walletBalance - credit : 0n;
  const next = Number(nextTier);
  const wait = secondsLeft(user.nextClaim);
  // The tier pairs' day counters start at the first activation; before it only the first pair is open.
  const start = firstActivation !== undefined && firstActivation > 0n ? firstActivation : undefined;
  const agentWait = secondsLeft(coolDown);
  const busy = Boolean(pending);
  // Day 1 is the activation day, counted in the contract's reward days.
  const incomeDays = firstActivation > 0n && day > 0n ? Math.floor((Date.now() / 1000 - Number(firstActivation)) / Number(day)) + 1 : 0;

  return (
    <>
      <section className="section">
        <div className="card card-body bg-mesh shape-bubbles relative mb-3 overflow-hidden border-0 text-center text-white shadow-glow">
          <p className="text-[11.5px] font-semibold uppercase tracking-wide text-white/75">{incomeDays > 0 ? `Total income in ${incomeDays.toLocaleString()} ${incomeDays === 1 ? "day" : "days"}` : "Total income"}</p>
          <p className="mt-1 text-3xl font-extrabold">{money(user.totalIncome)} <span className="text-[15px] font-bold text-white/75">USDT</span></p>
          <p className="mt-1 text-[12px] text-white/80">Lifetime daily, referral, generation, and leadership earnings</p>
        </div>
        <div className="card grid grid-cols-2 divide-x divide-line py-4 text-center">
          <div>
            <p className="text-xl font-extrabold">{money(user.walletBalance)}</p><p className="text-[11.5px] font-semibold text-muted">Wallet balance</p>
            {credit > 0n && <p className="mt-0.5 text-[11px] text-muted">Deposited {money(deposited)} · Rewards {money(credit)}</p>}
          </div>
          <div><p className={`text-xl font-extrabold ${hasTiers && cappingLeft === 0n ? "text-rose-500" : ""}`}>{money(cappingLeft)}</p><p className="text-[11.5px] font-semibold text-muted">Capping left</p></div>
        </div>
        {error && <p className="mt-3 text-center text-[12.5px] font-semibold text-rose-500" role="alert">{error}</p>}
      </section>

      <section className="section">
        <div className="section-head"><div>
          <h2 className="section-title">Collect</h2>
          <p className="section-sub">Daily, generation and leadership go to your wallet balance.</p>
        </div></div>
        <div className={`mb-3 rounded-2xl p-3 text-[12.5px] leading-relaxed ${usedUp ? "bg-rose-500/10 text-rose-500" : "bg-brand/8 text-muted"}`} role="note">
          {usedUp
            ? <><b>Your capping is used up.</b> Daily 1%, referral and generation rewards stop until you activate a tier. Amounts already shown below are still yours to collect.</>
            : <><b className="text-ink">Rewards stop at your capping.</b> Daily 1%, referral and generation are credited only up to your capping left. If 10 USDT is earned and 1 USDT of capping is left, you get 1 USDT and the other 9 USDT is gone. Leadership doesn't use capping.</>}
        </div>
        {credit !== undefined && (
          <div className={`mb-3 rounded-2xl p-3 text-[12.5px] leading-relaxed ${poolShort ? "bg-amber-500/10 text-amber-600" : "bg-brand/8 text-muted"}`} role="note">
            <b className={poolShort ? "" : "text-ink"}>Paid from the reward pool.</b> Daily and generation rewards are added to your wallet balance right away, and paid out from the reward pool, which the operator funds from trading. You have {money(credit)} USDT of them in your wallet{pool !== undefined && `; the pool holds ${money(pool)} USDT`}.
            {poolShort && " Withdrawing that part waits until the pool is funded. Activating with it needs the pool to hold 80% of the part you use, first come first served. Deposits can always be withdrawn or used to activate."}
          </div>
        )}
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
          <p className="section-sub">Paid from your wallet balance, in order. Each tier gives {lastCapBps === 20_000n ? "3x capping, the $1,600 tier 2x" : "3x capping"}.</p>
        </div></div>
        <div className="card card-body divide-y divide-line">
          {start !== undefined && <DayCounter start={start} day={day} />}
          {TIERS.map((_, tier) => (
            <TierRow
              key={tier}
              tier={tier}
              state={tierState(tier, next, cappings[tier], unlocked[tier] || (start !== undefined && secondsLeft(start + BigInt(Math.floor(tier / 2) * UNLOCK_DAYS) * day) === 0))}
              capping={cappings[tier]}
              capBps={tier === LAST ? lastCapBps : 30_000n}
              wallet={user.walletBalance}
              poolNeed={needTier !== undefined && BigInt(tier) === needTier ? poolNeed : undefined}
              poolHas={poolHas}
              busy={pending === `tier-${tier}`}
              disabled={busy}
              unlocked={unlocked[tier]}
              opensAt={start !== undefined ? start + BigInt(Math.floor(tier / 2) * UNLOCK_DAYS) * day : undefined}
              onActivate={(t) => run(`tier-${t}`, "activate", [BigInt(t)], `$${TIERS[t].toLocaleString()} tier activated.`)}
            />
          ))}
        </div>
      </section>
    </>
  );
}
