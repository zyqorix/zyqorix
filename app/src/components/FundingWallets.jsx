import { useState } from "react";
import { Trash2 } from "lucide-react";
import { useQueryClient } from "@tanstack/react-query";
import { erc20Abi, isAddress, maxUint256, parseUnits } from "viem";
import { useAccount, useReadContracts } from "wagmi";
import accountsAbi from "../config/abi/accounts.json";
import funderAbi from "../config/abi/funder.json";
import { CONTRACTS } from "../config/contracts.js";
import { ACTIVE_CHAIN_ID, BLOCK_TAG } from "../lib/appkit.js";
import { money } from "../lib/format.js";
import { reason, send } from "../lib/tx.js";

const funder = { address: CONTRACTS.funder, abi: funderAbi, chainId: ACTIVE_CHAIN_ID };
const usdt = { address: CONTRACTS.usdt, abi: erc20Abi, chainId: ACTIVE_CHAIN_ID };
const accounts = { address: CONTRACTS.accounts, abi: accountsAbi, chainId: ACTIVE_CHAIN_ID };
export const short = (a) => (a ? `${a.slice(0, 6)}…${a.slice(-4)}` : "—");
export const same = (a, b) => Boolean(a && b) && a.toLowerCase() === b.toLowerCase();

/** The funding wallets set on the funder. `supported` is false for a funder built before 2026-11-05. */
export function useFundingWallets() {
  const { data, isLoading } = useReadContracts({
    contracts: [{ ...funder, functionName: "fundingWallets" }],
    blockTag: BLOCK_TAG,
    query: { enabled: Boolean(CONTRACTS.funder), refetchInterval: 15_000 },
  });
  return { wallets: data?.[0]?.result ?? [], supported: data?.[0]?.status === "success", isLoading };
}

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

/** The client's funding wallets: each approves the funder once, and the USDT they hold (each up to its approval)
 *  is pulled in and booked like fundRewards when a withdrawal needs the pool, or here with Book now. */
export function FundingWallets() {
  const { address } = useAccount();
  const queryClient = useQueryClient();
  const [limit, setLimit] = useState("");
  const [next, setNext] = useState("");
  const [step, setStep] = useState("");
  const [error, setError] = useState("");
  const { wallets, supported, isLoading: listLoading } = useFundingWallets();

  const { data: head } = useReadContracts({
    contracts: [
      { ...funder, functionName: "pendingFunding" },
      { ...funder, functionName: "MAX_WALLETS" },
      { ...accounts, functionName: "owner" },
    ],
    blockTag: BLOCK_TAG,
    query: { enabled: supported, refetchInterval: 15_000 },
  });
  const [pending, max, owner] = head ? head.map((r) => r?.result) : [];

  const { data: funds } = useReadContracts({
    contracts: wallets.flatMap((w) => [
      { ...usdt, functionName: "balanceOf", args: [w] },
      { ...usdt, functionName: "allowance", args: [w, CONTRACTS.funder] },
    ]),
    blockTag: BLOCK_TAG,
    query: { enabled: wallets.length > 0, refetchInterval: 15_000 },
  });
  const mineIndex = wallets.findIndex((w) => same(w, address));
  const myAllowance = mineIndex >= 0 ? funds?.[mineIndex * 2 + 1]?.result : undefined;
  const isOwner = same(address, owner);

  if (!supported) {
    if (listLoading) return null;
    return <div className="card card-body mt-3"><p className="text-[13px] text-muted">This network's funder has no funding wallets.</p></div>;
  }

  const run = async (label, request) => {
    setError("");
    setStep(label);
    try {
      await send(request, address);
      await queryClient.invalidateQueries();
      setLimit("");
      setNext("");
    } catch (err) {
      setError(reason(err));
    }
    setStep("");
  };
  let parsedLimit = 0n;
  try { parsedLimit = limit ? parseUnits(limit, 18) : 0n; } catch { parsedLimit = 0n; }
  const approve = (amount) => run("Approve USDT…", { ...usdt, functionName: "approve", args: [CONTRACTS.funder, amount] });
  const full = max !== undefined && BigInt(wallets.length) >= max;

  return (
    <div className="card card-body mt-3">
      <p className="text-[13px] font-bold">Funding wallets</p>
      <p className="mt-1 text-[12px] text-muted">
        Each wallet approves the funder once, then just receives USDT. Withdrawals pull automatically when the reward pool is short; Book now is optional.
        Everything a wallet holds (up to its approval) counts as funding, so keep other money elsewhere. The same approval also covers that wallet's own Fund button.
      </p>

      <div className="mt-2">
        {wallets.length === 0 && <Row label="Wallets" value="None set" />}
        {wallets.map((w, i) => {
          const balance = funds?.[i * 2]?.result;
          const allowance = funds?.[i * 2 + 1]?.result;
          return (
            <div key={w} className="flex items-center justify-between gap-3 border-b border-line py-2">
              <div className="min-w-0">
                <p className="text-[13px] font-semibold">{short(w)}{same(w, address) && <span className="ml-1 text-[11px] text-brand">(you)</span>}</p>
                <p className="text-[11.5px] text-muted">
                  {balance !== undefined ? `${money(balance)} USDT` : "—"} · approved {allowance === undefined ? "—" : allowance === maxUint256 ? "unlimited" : money(allowance)}
                </p>
              </div>
              {isOwner && (
                <button type="button" className="btn btn-ghost btn-xs" disabled={Boolean(step)} aria-label={`Remove ${w}`}
                  onClick={() => run("Removing…", { ...funder, functionName: "removeFundingWallet", args: [w] })}><Trash2 className="size-3.5" /></button>
              )}
            </div>
          );
        })}
        <Row label="Waiting to be booked" note="All of it enters the reward pool" value={pending !== undefined ? `${money(pending)} USDT` : "—"} tone={pending > 0n ? "text-emerald-500" : ""} />
      </div>
      {error && <p className="mt-2 text-[12.5px] font-semibold text-rose-500" role="alert">{error}</p>}
      <button type="button" className="btn btn-primary btn-block mt-3" disabled={Boolean(step) || !address || !pending}
        onClick={() => run("Booking…", { ...funder, functionName: "pullFunding" })}>{step === "Booking…" ? step : "Book now"}</button>

      {mineIndex >= 0 && (
        <div className="mt-3 border-t border-line pt-3">
          <p className="text-[12px] font-semibold">You are a funding wallet</p>
          <div className="mt-2 flex gap-2">
            <input className="input input-filled flex-1" inputMode="decimal" placeholder="Approval limit (USDT)" value={limit} disabled={Boolean(step)}
              onChange={(e) => { setLimit(e.target.value.replace(/[^0-9.]/g, "")); setError(""); }} />
            <button type="button" className="btn btn-neutral btn-sm" disabled={Boolean(step) || parsedLimit === 0n} onClick={() => approve(parsedLimit)}>Approve</button>
          </div>
          <div className="mt-2 flex gap-2">
            <button type="button" className="btn btn-neutral btn-sm flex-1" disabled={Boolean(step)} onClick={() => approve(maxUint256)}>Approve unlimited</button>
            <button type="button" className="btn btn-ghost btn-sm flex-1" disabled={Boolean(step) || !myAllowance} onClick={() => approve(0n)}>Revoke</button>
          </div>
        </div>
      )}

      {isOwner && (
        <div className="mt-3 border-t border-line pt-3">
          <p className="text-[12px] font-semibold">Add a funding wallet (owner){max !== undefined && ` · ${wallets.length} of ${max}`}</p>
          <div className="mt-2 flex gap-2">
            <input className="input input-filled flex-1" placeholder="0x…" value={next} disabled={Boolean(step) || full}
              onChange={(e) => { setNext(e.target.value.trim()); setError(""); }} />
            <button type="button" className="btn btn-neutral btn-sm" disabled={Boolean(step) || full || !isAddress(next)}
              onClick={() => run("Adding…", { ...funder, functionName: "addFundingWallet", args: [next] })}>Add</button>
          </div>
          <p className="mt-1 text-[11.5px] text-muted">Use a wallet whose key the client holds (it signs the approval), not an exchange deposit address.</p>
        </div>
      )}
      {step && step !== "Booking…" && <p className="mt-2 text-[12px] text-muted">{step}</p>}
    </div>
  );
}
