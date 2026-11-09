import { Check, Hand, RefreshCw, X } from "lucide-react";
import { Link } from "react-router-dom";
import { useReadContracts } from "wagmi";
import HealthCard from "../components/HealthCard.jsx";
import { CHECKLIST } from "../config/adminChecklist.js";
import { DEPLOY_ORDER, REMIX_SETTINGS } from "../config/deployOrder.js";
import { ADMIN_CONTRACTS } from "../config/adminContracts.js";
import { CONTRACTS } from "../config/contracts.js";
import accountsAbi from "../config/abi/accounts.json";
import gatewayAbi from "../config/abi/gateway.json";
import liquidityAbi from "../config/abi/liquidity.json";
import vestingAbi from "../config/abi/vesting.json";
import zqrAbi from "../config/abi/zqrtoken.json";
import { ACTIVE_CHAIN_ID, BLOCK_TAG } from "../lib/appkit.js";

// Every checklist read, flattened in ADMIN_CONTRACTS order so one multicall covers the page.
const ROWS = ADMIN_CONTRACTS.flatMap((c) => (CHECKLIST[c.slug] ?? []).filter((item) => !item.skip).map((item) => ({ group: c, item })));

const POOL_ABI = [{
  type: "function", name: "slot0", stateMutability: "view", inputs: [],
  outputs: ["uint160", "int24", "uint16", "uint16", "uint16", "uint32", "bool"].map((type) => ({ name: "", type })),
}];
// Read targets outside ADMIN_CONTRACTS: the payment token, the V3 pool and the retired stack.
const EXTRA = {
  usdt: { address: CONTRACTS.usdt, abi: zqrAbi },
  pool: { address: CONTRACTS.pool, abi: POOL_ABI },
  retiredAccounts: { address: CONTRACTS.retired?.accounts, abi: accountsAbi },
  retiredGateway: { address: CONTRACTS.retired?.gateway, abi: gatewayAbi },
  retiredLiquidity: { address: CONTRACTS.retired?.liquidity, abi: liquidityAbi },
  retiredVesting: { address: CONTRACTS.retired?.vesting, abi: vestingAbi },
};

function call([slug, functionName, args]) {
  const target = EXTRA[slug] ?? ADMIN_CONTRACTS.find((c) => c.slug === slug);
  return { address: target.address, abi: target.abi, functionName, args, chainId: ACTIVE_CHAIN_ID };
}

/** One row per wiring call: a check when the chain reads back the expected value, a cross with the fix when not. */
function Checklist() {
  const live = ROWS.filter(({ group, item }) => group.address && !item.manual);
  const { data, isLoading, refetch } = useReadContracts({
    contracts: live.map(({ item }) => call(item.read)),
    blockTag: BLOCK_TAG,
    query: { enabled: live.length > 0, refetchInterval: 15_000 },
  });

  const status = new Map(live.map((row, i) => {
    const r = data?.[i];
    return [row.item, r ? r.status === "success" && row.item.ok(r.result) : undefined];
  }));
  const required = live.filter(({ item }) => !item.launch);
  const manual = ROWS.filter(({ item }) => item.manual).length;
  const done = required.filter(({ item }) => status.get(item)).length;

  return (
    <section className="section">
      <div className="section-head">
        <div>
          <h2 className="section-title">Configuration</h2>
          <p className="section-sub">{isLoading ? "Reading the contracts…" : `${done} of ${required.length} wiring steps set, ${manual} to check by hand. Launch locks are one-way and go last.`}</p>
        </div>
        <button type="button" className="btn btn-ghost btn-xs" onClick={() => refetch()}><RefreshCw className="size-3.5" />Refresh</button>
      </div>
      <div className="space-y-3">
        {ADMIN_CONTRACTS.filter((c) => CHECKLIST[c.slug]).map((c) => {
          const rows = ROWS.filter(({ group }) => group === c);
          const Icon = c.icon;
          return (
            <div key={c.slug} className="card card-body">
              <Link to={`/admin/${c.slug}`} className="mb-1 flex items-center gap-2 text-[13px] font-bold">
                <span className={`icon-box ${c.tone}`}><Icon className="size-4" /></span>{c.label}
              </Link>
              {rows.map(({ item }) => {
                const ok = item.manual ? null : c.address ? status.get(item) : false;
                return (
                  <div key={item.label} className="flex items-start gap-3 border-b border-line py-2 last:border-0">
                    {ok === null
                      ? <span className="mt-0.5 grid size-5 shrink-0 place-items-center rounded-full bg-line text-muted" aria-label="Check by hand"><Hand className="size-3" /></span>
                      : ok === undefined
                      ? <span className="mt-0.5 size-5 shrink-0 rounded-full bg-line" aria-label="Loading" />
                      : ok
                        ? <span className="mt-0.5 grid size-5 shrink-0 place-items-center rounded-full bg-emerald-500/15 text-emerald-500" aria-label="Set"><Check className="size-3.5" strokeWidth={3} /></span>
                        : <span className={`mt-0.5 grid size-5 shrink-0 place-items-center rounded-full ${item.launch ? "bg-amber-500/15 text-amber-500" : "bg-rose-500/15 text-rose-500"}`} aria-label="Not set"><X className="size-3.5" strokeWidth={3} /></span>}
                    <div className="min-w-0 flex-1">
                      <p className="flex items-center gap-2 text-[13px] font-semibold">
                        {item.label}
                        {item.manual && <span className="chip chip-soft">check by hand</span>}
                        {item.launch && <span className="chip bg-amber-500/12 text-amber-500">launch lock</span>}
                      </p>
                      {(ok === false || ok === null) && <p className="break-words font-mono text-[11.5px] text-muted">{c.address || item.manual ? item.fix : "not deployed on this network"}</p>}
                    </div>
                  </div>
                );
              })}
            </div>
          );
        })}
      </div>
    </section>
  );
}

const RETIRED = CONTRACTS.retired ?? {};
const isDeployed = (slug) => Boolean(CONTRACTS[slug]) && CONTRACTS[slug].toLowerCase() !== RETIRED[slug]?.toLowerCase();

/** The mainnet deploy order, top to bottom: each contract, its constructor and the tasks that follow it. */
function DeployOrder() {
  const done = DEPLOY_ORDER.filter((d) => d.slug && isDeployed(d.slug)).length;
  const total = DEPLOY_ORDER.filter((d) => d.slug).length;
  return (
    <section className="section">
      <div className="section-head">
        <div>
          <h2 className="section-title">Deploy order</h2>
          <p className="section-sub">{done} of {total} contracts deployed. {REMIX_SETTINGS}.</p>
        </div>
      </div>
      <ol className="space-y-3">
        {DEPLOY_ORDER.map((d) => {
          const deployed = d.slug ? isDeployed(d.slug) : null;
          return (
            <li key={d.step} className="card card-body">
              <div className="flex items-start gap-3">
                <span className={`grid size-7 shrink-0 place-items-center rounded-full text-[12px] font-extrabold ${deployed ? "bg-emerald-500/15 text-emerald-500" : "bg-line text-muted"}`}>
                  {deployed ? <Check className="size-4" strokeWidth={3} /> : d.step}
                </span>
                <div className="min-w-0 flex-1">
                  <p className="flex flex-wrap items-center gap-2 text-[13.5px] font-bold">
                    {d.label}
                    {d.slug && <span className={`chip ${deployed ? "bg-emerald-500/12 text-emerald-500" : "chip-soft"}`}>{deployed ? "deployed" : "to deploy"}</span>}
                  </p>
                  {d.contract && <p className="break-words font-mono text-[11.5px] text-muted">{d.file} · {d.contract}{d.args}</p>}
                  {deployed && <p className="break-all font-mono text-[11px] text-emerald-500">{CONTRACTS[d.slug]}</p>}
                  {d.note && <p className="mt-1 text-[12px] font-semibold text-amber-500">{d.note}</p>}
                  <ul className="mt-1.5 space-y-1">
                    {d.tasks.map((t) => <li key={t} className="flex gap-2 text-[12.5px]"><span className="mt-[7px] size-1 shrink-0 rounded-full bg-muted" />{t}</li>)}
                  </ul>
                </div>
              </div>
            </li>
          );
        })}
      </ol>
    </section>
  );
}

/** Admin home: one tile per contract, the health balance, the deploy order, then the configuration checklist. */
export default function Admin() {
  return (
    <>
      <section className="section">
        <div className="section-head"><div>
          <h2 className="section-title">Admin</h2>
          <p className="section-sub">Open a contract to read its state or send an admin transaction.</p>
        </div></div>
        <div className="grid grid-cols-4 gap-3 text-center text-[11.5px] font-semibold">
          {ADMIN_CONTRACTS.map(({ slug, label, icon: Icon, tone, address }) => (
            <Link key={slug} to={`/admin/${slug}`} className={`tap-scale flex flex-col items-center gap-2 ${address ? "" : "pointer-events-none opacity-40"}`}>
              <span className={`icon-box icon-box-lg ${tone}`}><Icon className="size-5" /></span>
              {label}
            </Link>
          ))}
        </div>
      </section>
      <HealthCard />
      <DeployOrder />
      <Checklist />
    </>
  );
}
