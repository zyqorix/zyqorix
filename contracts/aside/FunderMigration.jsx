import { useEffect, useState } from "react";
import { Check, ChevronRight, Copy } from "lucide-react";
import { erc20Abi, formatEther, getAddress, isAddress } from "viem";
import { useAccount, useBytecode, useReadContracts } from "wagmi";
import TxButton from "./TxButton.jsx";
import { useUi } from "./Ui.jsx";
import accountsAbi from "../config/abi/accounts.json";
import funderAbi from "../config/abi/funder.json";
import gatewayAbi from "../config/abi/gateway.json";
import { CONTRACTS } from "../config/contracts.js";
import { useTxAction } from "../hooks/useTxAction.js";
import { ACTIVE_CHAIN_ID, BLOCK_TAG } from "../lib/appkit.js";

const chainId = ACTIVE_CHAIN_ID;
const STORE = `zyqorix:funder-migration:${chainId}`;
const LEDGER = ["tradingCapitalOut", "tradingCapitalReturned", "capitalHeld", "rewardPool"];
const ZERO = "0x0000000000000000000000000000000000000000";

const same = (a, b) => Boolean(a && b) && a.toLowerCase() === b.toLowerCase();
const usdt = (v) => (typeof v === "bigint" ? `${Number(formatEther(v)).toLocaleString(undefined, { maximumFractionDigits: 6 })} USDT` : "—");
const short = (a) => (a ? `${a.slice(0, 6)}…${a.slice(-4)}` : "—");

function load() {
  try { return JSON.parse(localStorage.getItem(STORE)) ?? {}; } catch { return {}; }
}
function save(v) {
  try { localStorage.setItem(STORE, JSON.stringify(v)); } catch { /* private mode: the wizard still works for this visit */ }
}

/** One funder's wiring, ledger, seal and USDT balance. Undefined fields while loading or with no address. */
function useFunder(address) {
  const ok = isAddress(address ?? "");
  const base = { address, abi: funderAbi, chainId };
  const fns = ["gateway", "rewards", "tradingWallet", "accounts", "isSealed", "migratedTo", ...LEDGER];
  const { data, refetch } = useReadContracts({
    contracts: ok ? [...fns.map((functionName) => ({ ...base, functionName })),
      { address: CONTRACTS.usdt, abi: erc20Abi, functionName: "balanceOf", args: [address], chainId }] : [],
    blockTag: BLOCK_TAG,
    query: { enabled: ok, refetchInterval: 10_000 },
  });
  const out = {};
  fns.forEach((f, i) => { out[f] = data?.[i]?.status === "success" ? data[i].result : undefined; });
  out.balance = data?.[fns.length]?.status === "success" ? data[fns.length].result : undefined;
  return { ...out, refetch };
}

function Step({ n, title, done, open, children, last }) {
  return (
    <div className={`tl-item pl-3${last ? " pb-0!" : ""}`}>
      <span className={`tl-dot ${done ? "bg-emerald-500 text-white" : open ? "" : "bg-ink/10 text-muted"}`} aria-label={done ? "Done" : `Step ${n}`}>
        {done ? <Check /> : <span className="text-[13px] font-extrabold">{n}</span>}
      </span>
      <div className="flex items-center gap-2">
        <p className={`flex-1 text-[14px] font-bold ${open || done ? "" : "text-muted"}`}>{title}</p>
        {done && <span className="chip bg-emerald-500/12 text-emerald-500">Done</span>}
      </div>
      {(open || done) && <div className="mt-2 space-y-2 text-[12.5px]">{children}</div>}
    </div>
  );
}

function Row({ label, ok, value }) {
  return (
    <div className="flex items-start justify-between gap-3">
      <span className={ok === undefined ? "text-muted" : ok ? "text-emerald-500" : "text-rose-500"}>{ok === undefined ? "•" : ok ? "✓" : "✗"} {label}</span>
      <span className="break-all text-right font-mono text-[11.5px]">{value}</span>
    </div>
  );
}

/** A write with the usual TxButton lifecycle; refreshes the wizard once it confirms. */
function Action({ label, config, canRun, onDone, danger }) {
  const tx = useTxAction();
  useEffect(() => { if (tx.phase === "success") onDone(); }, [tx.phase]); // eslint-disable-line react-hooks/exhaustive-deps
  return <TxButton tx={tx} canRun={canRun} onRun={() => tx.run(config)} idleLabel={label} danger={danger} />;
}

/** Move from the live funder to a new, identical funder in one transaction: gateway.migrateFunder makes the old
 *  funder check the code, hand over its wiring, ledger and USDT, and seal itself. Every indicator is read from
 *  the chain, so the wizard can be left and resumed at any step. */
export default function FunderMigration() {
  const { toast } = useUi();
  const { address: me } = useAccount();
  const [saved, setSaved] = useState(load);
  const [text, setText] = useState(saved.to ?? "");
  const [sure, setSure] = useState(false);
  const [open, setOpen] = useState(Boolean(saved.to));

  const gw = { address: CONTRACTS.gateway, abi: gatewayAbi, chainId };
  const { data: g, refetch: refetchGateway } = useReadContracts({
    contracts: [
      { ...gw, functionName: "funder" }, { ...gw, functionName: "funderLocked" }, { ...gw, functionName: "rewards" },
      { address: CONTRACTS.accounts, abi: accountsAbi, functionName: "owner", chainId },
    ],
    blockTag: BLOCK_TAG,
    query: { refetchInterval: 10_000 },
  });
  const [liveFunder, locked, gatewayRewards, owner] = (g ?? []).map((r) => r?.result);

  const to = isAddress(text.trim()) ? getAddress(text.trim()) : undefined;
  const migrated = same(liveFunder, to);
  // The funder being replaced: the live one until the move, then the one recorded when the move started.
  // Without a saved pair (another browser), fall back to the address this build was configured with.
  const from = migrated ? saved.from ?? (same(CONTRACTS.funder, to) ? undefined : CONTRACTS.funder) : liveFunder;
  const oldF = useFunder(from);
  const newF = useFunder(to);
  const { data: oldCode } = useBytecode({ address: from, chainId, query: { enabled: isAddress(from ?? "") } });
  const { data: newCode } = useBytecode({ address: to, chainId, query: { enabled: Boolean(to) } });

  // Remember the pair so the wizard can show the old funder after gateway.funder() has moved on.
  useEffect(() => {
    if (!to || migrated || !liveFunder || same(to, liveFunder)) return;
    if (saved.to === to && same(saved.from, liveFunder)) return;
    const next = { from: liveFunder, to };
    setSaved(next);
    save(next);
  }, [to, liveFunder, migrated]); // eslint-disable-line react-hooks/exhaustive-deps

  const refresh = () => { refetchGateway(); oldF.refetch(); newF.refetch(); };
  const isOwner = same(me, owner);

  // Step 1: exactly the live funder's code. The funder enforces the same check (CODE_MISMATCH), and because
  // the accounts address is baked into the code, identical code also means the same accounts contract.
  const hasCode = Boolean(newCode && newCode !== "0x");
  const sameCode = hasCode && Boolean(oldCode) && newCode === oldCode;
  const s1 = Boolean(to) && (migrated || (!same(to, liveFunder) && sameCode));
  // Step 2: what migrateFunder needs: a fresh funder, an unlocked gateway, the owner wallet.
  const fresh = same(newF.gateway, ZERO) && same(newF.rewards, ZERO) && newF.tradingCapitalOut === 0n && newF.rewardPool === 0n;
  const s2 = s1 && (migrated || (fresh && locked === false && oldF.isSealed === false && isOwner));
  // Step 3: the gateway points at the new funder.
  const s3 = s2 && migrated;
  // Step 4: the old funder is sealed, points at the new one and is empty, and the wiring was copied. The ledger
  // is copied in the same transaction; members keep using the new funder afterwards, so it only matches the
  // sealed copy until the next activation or claim, and is shown for information.
  const wiringCopied = same(newF.gateway, CONTRACTS.gateway) && same(newF.rewards, gatewayRewards) && same(newF.tradingWallet, oldF.tradingWallet);
  const s4 = s3 && oldF.isSealed === true && same(oldF.migratedTo, to) && oldF.balance === 0n && wiringCopied;
  // Step 5: this build of the app knows the new address.
  const s5 = s4 && same(CONTRACTS.funder, to);
  const steps = [s1, s2, s3, s4, s5];
  const current = steps.findIndex((s) => !s);
  const isOpen = (i) => current === i;

  const copy = async (value, what) => {
    try { await navigator.clipboard.writeText(value); toast(`${what} copied.`); } catch { toast("Couldn't copy."); }
  };

  return (
    <div className="card card-body mb-3">
      <button type="button" className="flex w-full items-center gap-2 text-left" aria-expanded={open} onClick={() => setOpen((v) => !v)}>
        <ChevronRight className={`size-4 shrink-0 text-muted transition-transform ${open ? "rotate-90" : ""}`} />
        <span className="flex-1">
          <span className="block text-[15px] font-extrabold">Migrate to a new funder</span>
          <span className="block text-[12px] text-muted">
            {locked ? "Closed: the funder is locked on the gateway." : s5 ? "Migration complete." : current >= 0 && to ? `Step ${current + 1} of 5` : "Move the funds, ledger and wiring to an identical funder at a new address."}
          </span>
        </span>
      </button>

      {open && (
        <div className="mt-4">
          {locked && <p className="mb-3 rounded-xl bg-rose-500/10 p-3 text-[12px] font-semibold text-rose-500">gateway.lockFunder has been called, so the funder can't move any more.</p>}
          {!isOwner && <p className="mb-3 rounded-xl bg-amber-500/10 p-3 text-[12px] font-semibold text-amber-600">The migration needs the accounts owner wallet ({short(owner)}). This wallet can follow along but not send it.</p>}

          <div className="timeline-left">
            <Step n={1} title="Deploy the new funder and enter its address" done={s1} open={isOpen(0)}>
              <p className="text-muted">
                Deploy <span className="font-mono">funder.sol</span> (<span className="font-mono">ZyqorixFunder</span>) from the same build as the live funder, with constructor argument accounts. Nothing else needs setting on it.
              </p>
              <button type="button" className="flex w-full items-center gap-2 rounded-xl bg-brand/5 p-2.5 text-left font-mono text-[11.5px]" onClick={() => copy(CONTRACTS.accounts, "Accounts address")}>
                <span className="flex-1 break-all">{CONTRACTS.accounts}</span><Copy className="size-3.5 shrink-0" />
              </button>
              <label className="label mt-1" htmlFor="new-funder">New funder address</label>
              <input id="new-funder" className="input input-filled font-mono text-[13px]" type="text" autoComplete="off" spellCheck={false} placeholder="0x…"
                value={text} disabled={migrated} onChange={(e) => setText(e.target.value)} />
              {to && !migrated && (
                <div className="space-y-1 pt-1">
                  <Row label="Not the live funder" ok={!same(to, liveFunder)} value={short(liveFunder)} />
                  <Row label="Contract deployed" ok={newCode === undefined ? undefined : hasCode} value={hasCode ? `${(newCode.length - 2) / 2} bytes` : "no code"} />
                  <Row label="Exactly the live funder's code" ok={hasCode && oldCode ? sameCode : undefined} value={!hasCode || !oldCode ? "…" : sameCode ? "identical" : "different"} />
                  <Row label="Accounts contract" ok={newF.accounts === undefined ? undefined : same(newF.accounts, CONTRACTS.accounts)} value={short(newF.accounts)} />
                </div>
              )}
              {to && hasCode && oldCode && !sameCode && (
                <p className="font-semibold text-rose-500">
                  The code differs from the live funder, so the contract will refuse it (CODE_MISMATCH). Deploy it from the same build, with the same accounts address.
                </p>
              )}
            </Step>

            <Step n={2} title="Pre-flight check" done={s2} open={isOpen(1)}>
              <Row label="New funder is fresh (no gateway, rewards or ledger)" ok={migrated || fresh} value={`${short(newF.gateway)} · ${usdt(newF.rewardPool)}`} />
              <Row label="Live funder not sealed" ok={migrated || oldF.isSealed === false} value={String(oldF.isSealed)} />
              <Row label="Gateway funder not locked" ok={locked === false} value={String(locked)} />
              <Row label="Connected wallet is the owner" ok={migrated || isOwner} value={short(me)} />
              <p className="text-muted">Will move {usdt(oldF.balance)}, the wiring (gateway, rewards, trading wallet {short(oldF.tradingWallet)}) and this ledger:</p>
              {LEDGER.map((f) => <Row key={f} label={f} value={usdt(oldF[f])} />)}
            </Step>

            <Step n={3} title="Migrate the funder" done={s3} open={isOpen(2)}>
              {migrated
                ? <Row label="Gateway points at the new funder" ok value={short(liveFunder)} />
                : <Row label="Gateway points at" value={`${short(liveFunder)} → ${short(to)} after you send migrateFunder`} />}
              {!s3 && (
                <>
                  <p className="text-muted">
                    gateway.migrateFunder({short(to)}) does it all in one transaction: the old funder checks the code, wires the new one, moves every USDT and the ledger, and seals itself. All deposits, withdrawals and activations then use the new funder.
                  </p>
                  <p className="font-semibold">
                    Tick the box, then press Send migrateFunder and confirm in your wallet. This step turns green when the gateway points at the new funder.
                  </p>
                  <label className="flex items-start gap-2 text-[12px] font-semibold text-rose-500">
                    <input type="checkbox" checked={sure} onChange={(e) => setSure(e.target.checked)} />
                    I checked steps 1–2. Move all funds to {short(to)}.
                  </label>
                  <Action label="Send migrateFunder" danger canRun={s2 && sure} onDone={refresh}
                    config={{ ...gw, functionName: "migrateFunder", args: [to] }} />
                </>
              )}
            </Step>

            <Step n={4} title="Verify the move" done={s4} open={isOpen(3)}>
              <Row label="Old funder sealed" ok={oldF.isSealed === true && same(oldF.migratedTo, to)} value={`${short(from)} → ${short(oldF.migratedTo)}`} />
              <Row label="Old funder balance is 0" ok={oldF.balance === 0n} value={usdt(oldF.balance)} />
              <Row label="New funder balance" value={usdt(newF.balance)} />
              <Row label="Gateway, rewards, trading wallet copied" ok={wiringCopied} value={short(newF.tradingWallet)} />
              <p className="text-muted">Ledger: new funder now · sealed copy at the move. They differ once members activate or claim.</p>
              {LEDGER.map((f) => <Row key={f} label={f} value={`${usdt(newF[f])} · ${usdt(oldF[f])}`} />)}
            </Step>

            <Step n={5} title="Update the app and the exchangers" done={s5} open={isOpen(4)} last>
              <Row label="This app's funder address" ok={same(CONTRACTS.funder, to)} value={short(CONTRACTS.funder)} />
              <p className="text-muted">
                Set <span className="font-mono">funder</span> in <span className="font-mono">app/src/config/contracts.js</span> to the new address and republish. Send the exchangers the new address for fundRewards, and have them approve it. The old funder now rejects fundRewards (MIGRATED).
              </p>
              <button type="button" className="flex w-full items-center gap-2 rounded-xl bg-brand/5 p-2.5 text-left font-mono text-[11.5px]" onClick={() => copy(to ?? "", "New funder address")}>
                <span className="flex-1 break-all">{to}</span><Copy className="size-3.5 shrink-0" />
              </button>
            </Step>
          </div>
        </div>
      )}
    </div>
  );
}
