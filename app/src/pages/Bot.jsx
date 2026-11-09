import { useEffect, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { AlertTriangle, RefreshCw, Bot as BotIcon, Check, ChevronDown, Send, TrendingDown, TrendingUp, Undo2 } from "lucide-react";

// Live feed from the binance-spike-signal public API (projects/binance-spike-signal), docs at API/docs.
// One fetch of the last 24h every 30 s (the API rebuilds every 30 s); the kind filter runs client-side.
const API = "https://binancesignal.orbix.onl";
const TELEGRAM_URL = ""; // the subscribers' channel, once it exists
const PRICE_USDT = 20;

async function fetchSignals() {
  const res = await fetch(`${API}/v1/signals?limit=200`);
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  return res.json();
}

function useNow(ms = 30_000) {
  const [now, setNow] = useState(Date.now);
  useEffect(() => { const id = setInterval(() => setNow(Date.now()), ms); return () => clearInterval(id); }, [ms]);
  return now;
}

const ago = (ts, now) => {
  const m = Math.max(0, Math.floor((now - ts) / 60_000));
  return m < 60 ? `${m}m ago` : `${Math.floor(m / 60)}h${String(m % 60).padStart(2, "0")}m ago`;
};
const num = Number.isFinite;

const KIND = {
  pump: { label: "PUMP", icon: TrendingUp, chip: "bg-emerald-500/12 text-emerald-500" },
  dump: { label: "DUMP", icon: TrendingDown, chip: "bg-rose-500/12 text-rose-500" },
  reversal: { label: "REVERSAL", icon: Undo2, chip: "bg-violet-500/12 text-violet-500" },
  building: { label: "BUILDING", icon: AlertTriangle, chip: "bg-amber-500/12 text-amber-500" },
};
const FILTERS = [["all", "All"], ["pump", "Pump"], ["dump", "Dump"], ["reversal", "Reversal"], ["building", "Building"]];
const REGIME_TONE = { bull: "text-emerald-500", sideways: "text-muted", bear: "text-rose-500" };

const pct = (x, d = 1) => (Number.isFinite(x) ? `${x >= 0 ? "+" : "−"}${Math.abs(x).toFixed(d)}%` : "–");
const fmtPx = (x) => (num(x) ? x.toLocaleString("en-US", { maximumFractionDigits: 10 }) : "–");
const quoteOf = (symbol) => symbol?.match(/(USDT|USDC)$/)?.[1] ?? "";
const regimeLabel = (r) =>`${r.state.toUpperCase()} (${pct(r.ret)})`;

function Stat({ label, value, sub, tone = "" }) {
  return (
    <div className="min-w-0">
      <p className="text-[10.5px] font-semibold uppercase tracking-wide text-muted">{label}</p>
      <p className={`truncate text-[13.5px] font-bold ${tone}`}>{value}</p>
      {sub && <p className="truncate text-[11px] text-muted">{sub}</p>}
    </div>
  );
}

function RegimeBar({ label, value, tone }) {
  return (
    <div>
      <div className="flex justify-between text-[12px]"><span className="font-semibold">{label}</span><span className="font-bold">{value}%</span></div>
      <div className="mt-1 h-1.5 overflow-hidden rounded-full bg-line"><div className={`h-full rounded-full ${tone}`} style={{ width: `${value}%` }} /></div>
    </div>
  );
}

function Row({ k, v }) {
  return <div className="flex justify-between gap-3 py-1 text-[12.5px]"><span className="text-muted">{k}</span><span className="text-right font-semibold">{v}</span></div>;
}

function SignalCard({ s, now }) {
  const [open, setOpen] = useState(false);
  const k = KIND[s.kind];
  const Icon = k.icon;
  const up = s.movePct >= 0;
  const spikeSub = s.kind === "reversal" ? "from peak" : num(s.minutes) ? `in ${s.minutes}m` : "";

  return (
    <div className="card card-body">
      {/* Time + symbol */}
      <div className="flex items-start justify-between gap-3">
        <div className="flex min-w-0 items-center gap-2.5">
          <span className={`icon-box ${k.chip}`}><Icon className="size-[18px]" /></span>
          <div className="min-w-0">
            <p className="truncate text-[15px] font-extrabold">{s.coin} <span className="text-[12px] font-semibold text-muted">{s.symbol}{s.market === "perp" ? " perp" : ""}</span></p>
            <p className="text-[11.5px] text-muted">Binance · {s.kind === "reversal" ? s.liquidity : s.tier ? `Move ${s.tier}%+ in 15m` : "early warning"}</p>
          </div>
        </div>
        <div className="shrink-0 text-right">
          <p className="text-[13px] font-bold">{s.time}</p>
          <p className="text-[11px] text-muted">{ago(s.ts, now)}</p>
        </div>
      </div>

      {/* Price: the signal's own market first, both markets underneath when it trades on both */}
      <div className="mt-3 border-y border-line py-3 text-center dark:border-white/15">
        <p className="text-[10.5px] font-semibold uppercase tracking-wide text-muted">Price</p>
        <p className="truncate text-[24px] font-extrabold leading-tight tabular-nums">
          {fmtPx((s.market === "perp" ? s.perp : s.spot) ?? s.price)} <span className="text-[12px] font-semibold text-muted">{quoteOf(s.symbol)}</span>
        </p>
        {num(s.spot) && num(s.perp) && (
          <p className="mt-0.5 truncate text-[11.5px] text-muted tabular-nums">Spot {fmtPx(s.spot)} · Perp {fmtPx(s.perp)}{num(s.gapPct) ? ` (gap ${pct(s.gapPct, 2)})` : ""}</p>
        )}
      </div>

      {/* Spike + funding */}
      <div className="mt-3 grid grid-cols-3 gap-3 rounded-xl bg-line/40 p-3">
        <div>
          <p className="text-[10.5px] font-semibold uppercase tracking-wide text-muted">Spike</p>
          <span className={`chip mt-0.5 ${k.chip}`}>{k.label}</span>
        </div>
        <Stat label={up ? "Pump" : "Dump"} value={pct(s.movePct)} sub={spikeSub} tone={up ? "text-emerald-500" : "text-rose-500"} />
        <Stat label="Funding" value={Number.isFinite(s.funding) ? pct(s.funding, 4) : "–"} sub={Number.isFinite(s.funding) ? "current rate" : "spot only"} tone={s.funding < 0 ? "text-rose-500" : ""} />
      </div>

      {/* Regime: Markov 4h odds from the current regime */}
      <div className="mt-3 space-y-2">
        <p className="text-[11.5px] text-muted">Next 4h from <span className={`font-bold ${REGIME_TONE[s.markov.from]}`}>{s.markov.from.toUpperCase()}</span> (Markov)</p>
        <RegimeBar label="Regime Bull" value={s.markov.bull} tone="bg-emerald-500" />
        <RegimeBar label="Regime Bear" value={s.markov.bear} tone="bg-rose-500" />
        <RegimeBar label="Regime Sideways" value={s.markov.sideways} tone="bg-slate-400" />
      </div>

      <button type="button" className="mt-3 flex w-full items-center justify-center gap-1 text-[12.5px] font-semibold text-brand" onClick={() => setOpen((o) => !o)} aria-expanded={open}>
        {open ? "Hide details" : "Full signal"} <ChevronDown className={`size-4 transition-transform ${open ? "rotate-180" : ""}`} />
      </button>

      {open && (
        <div className="mt-2 space-y-3 border-t border-line pt-3">
          <div>
            <p className="mb-1 text-[11.5px] font-bold uppercase tracking-wide text-muted">Market</p>
            {s.reversal && <>
              <Row k="Pump before the turn" v={`${pct(s.reversal.pumpPct)}, peak ${s.reversal.peakMinAgo}m ago`} />
              <Row k="Gave back" v={`${s.reversal.givebackPct}% of the pump`} />
              <Row k="Peak → now" v={`${s.reversal.peak} → ${s.reversal.now}`} />
              <Row k="Pump low" v={s.reversal.pumpLow} />
            </>}
            {num(s.spot) && <Row k="Spot price" v={s.spot} />}
            {num(s.perp) && <Row k="Perp price" v={num(s.gapPct) ? `${s.perp} (gap ${pct(s.gapPct, 2)})` : s.perp} />}
            {!num(s.spot) && !num(s.perp) && num(s.price) && <Row k="Price" v={s.price} />}
            {num(s.volMultiple) && <Row k={s.reversal ? "Pump volume" : "Volume"} v={`${s.volMultiple.toFixed(1)}× average`} />}
            {num(s.retention) && <Row k="Retention" v={`${s.retention}% of the move held`} />}
            {Number.isFinite(s.oiPct) && <Row k={`Open interest (${s.oiLabel})`} v={pct(s.oiPct)} />}
            {Number.isFinite(s.funding) && <Row k="Funding rate" v={pct(s.funding, 4)} />}
            {s.turnover24h && <Row k="24h turnover" v={s.turnover24h} />}
            {s.members?.length > 0 && <Row k="Markets" v={s.members.join(" · ")} />}
          </div>

          <div>
            <p className="mb-1 text-[11.5px] font-bold uppercase tracking-wide text-muted">Regime ({s.regime.hours}h)</p>
            <Row k="Before the move" v={<span className={REGIME_TONE[s.regime.before.state]}>{regimeLabel(s.regime.before)}</span>} />
            <Row k="Now" v={<span className={REGIME_TONE[s.regime.now.state]}>{regimeLabel(s.regime.now)}</span>} />
            <Row k="Markov signal" v={`${s.markov.signal >= 0 ? "+" : "−"}${Math.abs(s.markov.signal)}% ${s.markov.right != null ? ` · historically right ${s.markov.right}%` : ""}`} />
            {s.switch && <Row k="Regime switch" v={`${s.switch.state} · ${s.switch.text}${s.switch.skipped ? " → short skipped" : " → short as usual"}`} />}
            {s.bot && <Row k="Bot" v={`${s.bot.decision}${s.bot.reason ? ` (${s.bot.reason.replace(/_/g, " ")})` : ""}`} />}
          </div>

          {s.plan && (
            <div>
              <p className="mb-1 text-[11.5px] font-bold uppercase tracking-wide text-muted">Trade plan</p>
              <div className="mb-1.5 flex flex-wrap gap-1.5">
                <span className={`chip ${s.plan.side === "LONG" ? "bg-emerald-500/12 text-emerald-500" : "bg-rose-500/12 text-rose-500"}`}>{s.plan.side}{s.plan.trigger === "breakout" ? " on breakout" : ""}</span>
                <span className="chip chip-soft">Confidence {s.plan.confidence}</span>
              </div>
              <Row k={s.plan.trigger === "breakout" ? "Trigger" : "Entry"} v={`≈ ${s.plan.entry}`} />
              <p className="pb-1 text-[11.5px] text-muted">{s.plan.entryNote}</p>
              <Row k="Take profit" v={s.plan.tps.join(" · ")} />
              <Row k="Stop loss" v={s.plan.sl} />
              <p className="pt-1 text-[11.5px] text-muted">{s.plan.how}</p>
            </div>
          )}

          {s.backtest && (
            <div>
              <p className="mb-1 text-[11.5px] font-bold uppercase tracking-wide text-muted">Backtest ({s.backtest.days} days)</p>
              <Row k="Win rate" v={`${s.backtest.win}% · n=${s.backtest.n}`} />
              <Row k="Average per trade" v={pct(s.backtest.avg)} />
              {s.backtest.pDown4h != null && <Row k="Price 4h later" v={`lower ${s.backtest.pDown4h}% · higher ${100 - s.backtest.pDown4h}%`} />}
            </div>
          )}

          <p className="text-[11px] text-muted">Not financial advice: a forecast based on backtest results.</p>
        </div>
      )}
    </div>
  );
}

const PERKS = ["Every pump, dump and reversal alert in real time", "Trade plan with entry, take profit and stop loss", "Regime odds and backtest stats on each signal", "4h top movers digest"];

/** Spike-signal bot page: the live alert feed from the signal API and the Telegram subscription. */
export default function Bot() {
  const [filter, setFilter] = useState("all");
  const now = useNow();
  const { data, isPending, isError, refetch, isFetching } = useQuery({ queryKey: ["spike-signals"], queryFn: fetchSignals, refetchInterval: 30_000, staleTime: 25_000, retry: 1 });
  const signals = data?.signals ?? [];
  const list = signals.filter((s) => filter === "all" || s.kind === filter);
  const stats = [
    [data ? data.count : "–", "Alerts 24h"],
    [data ? signals.filter((s) => s.kind === "pump").length : "–", "Pump"],
    [data ? signals.filter((s) => s.kind === "dump").length : "–", "Dump"],
    [data ? signals.filter((s) => s.kind === "reversal").length : "–", "Reversal"],
    [data ? signals.filter((s) => s.kind === "building").length : "–", "Building"],
  ];
  const filterLabel = FILTERS.find(([k]) => k === filter)[1].toLowerCase();

  return (
    <>
      <section className="section">
        <div className="card card-body bg-mesh shape-bubbles relative overflow-hidden border-0 text-white shadow-glow">
          <div className="flex items-center gap-3">
            <span className="icon-box icon-box-lg bg-white/20 text-white"><BotIcon className="size-6" /></span>
            <div>
              <h2 className="text-xl font-extrabold">Spike Signal Bot</h2>
              <p className="text-[12.5px] text-white/80">Binance spot and futures, watched every minute</p>
            </div>
          </div>
          <div className="mt-4 grid grid-cols-5 gap-1 text-center">
            {stats.map(([v, l]) => <div key={l}><p className="text-lg font-extrabold">{v}</p><p className="text-[11px] text-white/80">{l}</p></div>)}
          </div>
        </div>
      </section>

      <section className="section pt-0">
        <div className="section-head"><div>
          <h2 className="section-title">Latest signals</h2>
          <p className="section-sub">Local Time <span className="chip chip-soft ml-1">UTC +8</span>{data && <span className="ml-2">Updated {ago(data.updatedAt, now).replace("0m ago", "just now")}</span>}</p>
        </div>
        <button type="button" className="btn btn-ghost btn-xs" onClick={() => refetch()} disabled={isFetching}><RefreshCw className={`size-3.5 ${isFetching ? "animate-spin" : ""}`} />Refresh</button>
        </div>
        <div className="-mx-1 mb-3 flex gap-1.5 overflow-x-auto px-1 pb-1">
          {FILTERS.map(([key, label]) => (
            <button key={key} type="button" onClick={() => setFilter(key)} className={`chip shrink-0 ${filter === key ? "bg-brand text-white" : "chip-soft"}`}>{label}</button>
          ))}
        </div>
        <div className="space-y-3">
          {isPending && [0, 1, 2].map((i) => <div key={i} className="card card-body h-44 animate-pulse bg-line/40" />)}
          {isError && !data && (
            <div className="card card-body text-center">
              <p className="text-[13.5px] font-bold">Signals unavailable right now</p>
              <p className="text-[12px] text-muted">The signal feed could not be reached. Try again in a minute.</p>
              <button type="button" className="btn btn-primary mt-3" onClick={() => refetch()}>Try again</button>
            </div>
          )}
          {data && list.length === 0 && <div className="card card-body text-center text-[13px] text-muted">No {filter === "all" ? "" : `${filterLabel} `}signals in the last 24h.</div>}
          {list.map((s) => <SignalCard key={s.id} s={s} now={now} />)}
        </div>
      </section>

      <section className="section pt-0">
        <div className="section-head"><div><h2 className="section-title">Get every signal</h2></div></div>
        <div className="card card-body">
          <div className="flex items-end justify-between">
            <div>
              <p className="text-[11.5px] font-semibold uppercase tracking-wide text-muted">Subscription</p>
              <p className="text-3xl font-extrabold">{PRICE_USDT} <span className="text-[15px] font-bold text-muted">USDT</span></p>
            </div>
            <span className="chip chip-soft">per month</span>
          </div>
          <ul className="mt-3 space-y-2">
            {PERKS.map((p) => <li key={p} className="flex gap-2 text-[13px]"><Check className="mt-0.5 size-4 shrink-0 text-brand" />{p}</li>)}
          </ul>
          {TELEGRAM_URL
            ? <a href={TELEGRAM_URL} target="_blank" rel="noreferrer" className="btn btn-primary mt-4 w-full"><Send className="size-4" /> Subscribe on Telegram</a>
            : <button type="button" className="btn btn-primary mt-4 w-full" disabled><Send className="size-4" /> Subscribe on Telegram</button>}
          <p className="mt-2 text-center text-[11.5px] text-muted">Opens our private Telegram channel. Signals are not financial advice.</p>
        </div>
      </section>
    </>
  );
}
