import { useEffect, useState } from "react";
import { Link, Navigate, useParams } from "react-router-dom";
import { ArrowLeft, ChevronRight, Copy, RefreshCw } from "lucide-react";
import { erc20Abi, formatEther, getAddress, isAddress, parseEther } from "viem";
import TxButton from "../components/TxButton.jsx";
import { useUi } from "../components/Ui.jsx";
import { IRREVERSIBLE } from "../config/adminContracts.js";
import { useAdminContract } from "../hooks/useAdminContract.js";
import { useApproval } from "../hooks/useApproval.js";
import { useTxAction } from "../hooks/useTxAction.js";

/* ------------------------------ Conversion bridge ------------------------------ */
// Inbound: inputs stay plain strings and are converted once, in the handler. A uint marked "18 dp" is a
// token amount (USDT or ZQR) and goes through parseEther; "raw" is passed as an integer (bps, counts, seconds).
const RAW_NAME = /bps|count|month|tier|limit|cooldown|seconds|index|id$|level|slots|window|mode/i;
const TOKEN_NAME = /amount|price|profit|deposit|reserve|fund|balance|value|capital|held|pool|min|max|step|out|returned/i;
const defaultDecimals = (input) => /^u?int/.test(input.type) && !RAW_NAME.test(input.name) && TOKEN_NAME.test(input.name);

function parseValue(input, text, asToken) {
  const t = input.type;
  const v = text.trim();
  if (t.endsWith("]")) {
    const inner = { ...input, type: t.slice(0, t.lastIndexOf("[")) };
    const items = v.startsWith("[") ? JSON.parse(v).map(String) : v === "" ? [] : v.split(",");
    return items.map((item) => parseValue(inner, item, asToken));
  }
  if (t === "tuple") return JSON.parse(v);
  if (t === "address") {
    if (!isAddress(v)) throw new Error(`${input.name || "address"}: enter a full 0x address`);
    return getAddress(v);
  }
  if (t === "bool") return v === "true";
  if (/^u?int/.test(t)) {
    if (v === "" || Number.isNaN(Number(v))) throw new Error(`${input.name || t}: enter a number`);
    if (asToken) return parseEther(v);
    if (!/^-?\d+$/.test(v)) throw new Error(`${input.name || t}: whole numbers only, or switch to 18 dp`);
    return BigInt(v);
  }
  return v; // string, bytes
}

/* ------------------------------ Outbound display ------------------------------ */
const json = (v) => JSON.stringify(v, (_, x) => (typeof x === "bigint" ? x.toString() : x), 1);

function Value({ value, output }) {
  if (value === undefined) return <span className="text-muted">—</span>;
  if (typeof value === "bigint") {
    const asToken = value >= 10n ** 15n && !RAW_NAME.test(output?.name ?? "");
    return (
      <span className="text-right">
        {asToken && <span className="block font-bold">{Number(formatEther(value)).toLocaleString(undefined, { maximumFractionDigits: 6 })}</span>}
        <span className={`block font-mono ${asToken ? "text-[11px] text-muted" : "font-bold"}`}>{value.toLocaleString()}</span>
      </span>
    );
  }
  if (typeof value === "boolean") return <span className={`font-bold ${value ? "text-emerald-500" : "text-muted"}`}>{value ? "true" : "false"}</span>;
  if (typeof value === "string") return <span className="break-all font-mono text-[12px]">{value}</span>;
  if (Array.isArray(value) && value.length > 0 && value.every((x) => typeof x === "bigint" || typeof x === "string")) {
    return <span className="space-y-1 text-right">{value.map((x, i) => <span key={i} className="block"><Value value={x} output={output} /></span>)}</span>;
  }
  if (Array.isArray(value) && value.length === 0) return <span className="text-muted">empty</span>;
  return <pre className="max-h-48 overflow-auto whitespace-pre-wrap break-all text-left font-mono text-[11px]">{json(value)}</pre>;
}

function Result({ result, fn }) {
  if (fn.outputs.length <= 1) return <Value value={result} output={fn.outputs[0]} />;
  const list = Array.isArray(result) ? result : fn.outputs.map((o) => result?.[o.name]);
  return (
    <div className="w-full space-y-1">
      {fn.outputs.map((o, i) => (
        <div key={i} className="flex items-start justify-between gap-3 text-[12.5px]">
          <span className="text-muted">{o.name || `#${i}`}</span>
          <Value value={list[i]} output={o} />
        </div>
      ))}
    </div>
  );
}

/* ------------------------------ Inputs ------------------------------ */
function Inputs({ fn, texts, setTexts, tokens, setTokens, disabled }) {
  return fn.inputs.map((input, i) => {
    const isUint = /^u?int\d*$/.test(input.type);
    return (
      <div key={i} className="space-y-1">
        <label className="flex items-center justify-between text-[11.5px] font-semibold text-muted">
          <span>{input.name || `arg ${i}`} <span className="font-mono">({input.type})</span></span>
          {isUint && (
            <button type="button" className="chip chip-soft" disabled={disabled} onClick={() => setTokens({ ...tokens, [i]: !tokens[i] })}>
              {tokens[i] ? "18 dp" : "raw"}
            </button>
          )}
        </label>
        {input.type === "bool" ? (
          <select className="input input-filled" value={texts[i] ?? "false"} disabled={disabled} onChange={(e) => setTexts({ ...texts, [i]: e.target.value })}>
            <option value="false">false</option>
            <option value="true">true</option>
          </select>
        ) : (
          <input className="input input-filled font-mono text-[13px]" type="text" autoComplete="off" spellCheck={false} disabled={disabled}
            placeholder={input.type === "address" ? "0x…" : input.type.endsWith("]") ? "comma separated" : isUint ? (tokens[i] ? "e.g. 50" : "e.g. 500") : ""}
            value={texts[i] ?? ""} onChange={(e) => setTexts({ ...texts, [i]: e.target.value })} />
        )}
      </div>
    );
  });
}

function useArgs(fn) {
  const [texts, setTexts] = useState({});
  const [tokens, setTokens] = useState(() => Object.fromEntries(fn.inputs.map((input, i) => [i, defaultDecimals(input)])));
  let args;
  let error = "";
  try {
    args = fn.inputs.map((input, i) => parseValue(input, texts[i] ?? (input.type === "bool" ? "false" : ""), tokens[i]));
  } catch (e) {
    error = e.message;
  }
  return { texts, setTexts, tokens, setTokens, args, error };
}

/* ------------------------------ Function cards ------------------------------ */
function Card({ fn, children, badge }) {
  const [open, setOpen] = useState(false);
  return (
    <div className="border-b border-line last:border-0">
      <button type="button" className="flex w-full items-center gap-2 py-3 text-left" aria-expanded={open} onClick={() => setOpen((v) => !v)}>
        <ChevronRight className={`size-4 shrink-0 text-muted transition-transform ${open ? "rotate-90" : ""}`} />
        <span className="min-w-0 flex-1 truncate font-mono text-[13px] font-semibold">{fn.name}</span>
        {badge}
      </button>
      {open && <div className="space-y-3 pb-4 pl-6">{children}</div>}
    </div>
  );
}

function ReadCard({ fn, query }) {
  const a = useArgs(fn);
  const [result, setResult] = useState(undefined);
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const run = async () => {
    setBusy(true);
    setError("");
    try { setResult(await query(fn, a.args)); } catch (e) { setResult(undefined); setError(e.shortMessage || e.message); }
    setBusy(false);
  };
  return (
    <Card fn={fn}>
      <Inputs fn={fn} {...a} disabled={busy} />
      {a.error && <p className="text-[12px] text-rose-500">{a.error}</p>}
      <button type="button" className="btn btn-soft btn-sm" disabled={busy || Boolean(a.error)} onClick={run}>{busy ? "Reading…" : "Query"}</button>
      {error && <p className="break-words text-[12px] text-rose-500">{error}</p>}
      {result !== undefined && <div className="rounded-xl bg-brand/5 p-3"><Result result={result} fn={fn} /></div>}
    </Card>
  );
}

const tokens = (v) => (typeof v === "bigint" ? Number(formatEther(v)).toLocaleString(undefined, { maximumFractionDigits: 6 }) : "—");
const shortAddr = (w) => `${w.slice(0, 6)}…${w.slice(-4)}`;

/** Allowance status for a write that pulls tokens, with an Approve step when the connected wallet pays. */
function ApprovalStep({ approval, approveTx }) {
  if (!approval.ready) return <p className="text-[12px] text-muted">Fill in the form to check the {approval.symbol} allowance this call needs.</p>;
  const { symbol, amount, allowance, balance, enough, covered, payer, spender, payerIsMe, spenderIsMe } = approval;
  return (
    <div className="space-y-2 rounded-xl bg-brand/5 p-3 text-[12px]">
      <p className="font-bold">Needs {tokens(amount)} {symbol} approved</p>
      <p className="text-muted">
        Allowance {tokens(allowance)} {symbol} · payer balance {tokens(balance)} {symbol}
        <br />Payer {payerIsMe ? "your wallet" : shortAddr(payer)} → spender {spenderIsMe ? "your wallet" : shortAddr(spender)}
      </p>
      {!covered && <p className="font-semibold text-rose-500">The payer holds less than {tokens(amount)} {symbol}.</p>}
      {enough ? (
        <p className="font-semibold text-emerald-500">Allowance is enough.</p>
      ) : payerIsMe && !spenderIsMe ? (
        <TxButton tx={approveTx} canRun={covered} idleLabel={`Approve ${tokens(amount)} ${symbol}`}
          onRun={() => approveTx.run({ address: approval.token, abi: erc20Abi, functionName: "approve", args: [spender, amount] })} />
      ) : (
        <p className="font-semibold text-amber-500">
          {payerIsMe ? "Your wallet" : shortAddr(payer)} must first approve {spenderIsMe ? "your wallet" : shortAddr(spender)} for {tokens(amount)} {symbol}. That can only be signed by the payer.
        </p>
      )}
    </div>
  );
}

function WriteCard({ slug, fn, base, onDone }) {
  const a = useArgs(fn);
  const tx = useTxAction();
  const approveTx = useTxAction();
  const approval = useApproval(slug, fn, base.address, a.error ? undefined : a.args);
  const danger = IRREVERSIBLE.has(fn.name);
  const [sure, setSure] = useState(false);
  const approved = !approval || (approval.ready && approval.enough && approval.covered);
  const canRun = !a.error && (!danger || sure) && approved;
  const run = async () => {
    console.log(fn.name, "args:", a.texts, "→", a.args);
    await tx.run({ ...base, functionName: fn.name, args: a.args });
    onDone();
    approval?.refetch();
  };
  const approvePhase = approveTx.phase;
  useEffect(() => { if (approvePhase === "success") approval?.refetch(); }, [approvePhase]); // eslint-disable-line react-hooks/exhaustive-deps
  return (
    <Card fn={fn} badge={danger && <span className="chip bg-rose-500/12 text-rose-500">irreversible</span>}>
      <Inputs fn={fn} {...a} disabled={tx.busy} />
      {a.error && Object.keys(a.texts).length > 0 && <p className="text-[12px] text-rose-500">{a.error}</p>}
      {danger && (
        <label className="flex items-start gap-2 text-[12px] font-semibold text-rose-500">
          <input type="checkbox" checked={sure} onChange={(e) => setSure(e.target.checked)} disabled={tx.busy} />
          I understand this can't be undone or moves control or all funds.
        </label>
      )}
      {approval && <ApprovalStep approval={approval} approveTx={approveTx} />}
      <TxButton tx={tx} canRun={canRun} onRun={run} idleLabel={`Send ${fn.name}`} danger={danger} />
    </Card>
  );
}

/* ------------------------------ Page ------------------------------ */
/** Read and write any function of one contract. Owner and admin checks stay on-chain: a call this wallet
 *  isn't allowed to make fails its gas estimate with the contract's reason before anything is signed. */
export default function AdminContract() {
  const { slug } = useParams();
  const { toast } = useUi();
  const { entry, base, reads, writes, values, query, refetch, isLoading } = useAdminContract(slug);
  const [tab, setTab] = useState("read");
  const [filter, setFilter] = useState("");

  if (!entry || !entry.address) return <Navigate to="/admin" replace />;

  const match = (fn) => fn.name.toLowerCase().includes(filter.trim().toLowerCase());
  const plain = reads.filter((f) => f.inputs.length === 0 && match(f));
  const withArgs = reads.filter((f) => f.inputs.length > 0 && match(f));
  const shownWrites = writes.filter(match);
  const copy = async () => {
    try { await navigator.clipboard.writeText(entry.address); toast("Contract address copied."); } catch { toast("Couldn't copy the address."); }
  };
  const Icon = entry.icon;

  return (
    <section className="section">
      <Link to="/admin" className="mb-3 inline-flex items-center gap-1 text-[13px] font-semibold text-brand"><ArrowLeft className="size-4" />Admin</Link>

      <div className="card card-body mb-3 flex items-center gap-3">
        <span className={`icon-box icon-box-lg ${entry.tone}`}><Icon className="size-5" /></span>
        <div className="min-w-0 flex-1">
          <h2 className="text-lg font-extrabold">{entry.label}</h2>
          <p className="truncate font-mono text-[12px] text-muted">{entry.address}</p>
        </div>
        <button type="button" className="btn btn-ghost btn-xs btn-square" aria-label="Copy contract address" onClick={copy}><Copy className="size-4" /></button>
      </div>


      <div className="tabs-pills mb-3">
        {[["read", `Read (${reads.length})`], ["write", `Write (${writes.length})`]].map(([key, label]) => (
          <button key={key} type="button" className={tab === key ? "is-active" : ""} aria-pressed={tab === key} onClick={() => setTab(key)}>{label}</button>
        ))}
      </div>
      <input className="input input-filled mb-3 text-[13px]" type="search" placeholder="Filter functions" aria-label="Filter functions" value={filter} onChange={(e) => setFilter(e.target.value)} />

      {tab === "read" ? (
        <>
          <div className="card card-body mb-3">
            <div className="mb-1 flex items-center justify-between">
              <p className="text-[12px] font-bold uppercase tracking-wide text-muted">State</p>
              <button type="button" className="btn btn-ghost btn-xs" onClick={() => refetch()}><RefreshCw className="size-3.5" />Refresh</button>
            </div>
            {isLoading ? <p className="py-2 text-[13px] text-muted">Loading…</p> : plain.map((fn) => (
              <div key={fn.name} className="flex items-start justify-between gap-3 border-b border-line py-2 last:border-0">
                <span className="min-w-0 truncate font-mono text-[12.5px]">{fn.name}</span>
                {values[fn.name]?.status === "failure"
                  ? <span className="text-[12px] text-rose-500">reverted</span>
                  : <Result result={values[fn.name]?.result} fn={fn} />}
              </div>
            ))}
          </div>
          {withArgs.length > 0 && <div className="card card-body">{withArgs.map((fn) => <ReadCard key={fn.name} fn={fn} query={query} />)}</div>}
        </>
      ) : (
        <div className="card card-body">
          <p className="mb-1 text-[12px] text-muted">Each call is estimated first, so a function this wallet isn't allowed to call shows the contract's reason before anything is signed.</p>
          {shownWrites.map((fn) => <WriteCard key={fn.name} slug={slug} fn={fn} base={base} onDone={refetch} />)}
        </div>
      )}
    </section>
  );
}
