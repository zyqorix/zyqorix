import { useState } from "react";
import { CircleAlert } from "lucide-react";
import { useQueryClient } from "@tanstack/react-query";
import { erc20Abi, parseUnits } from "viem";
import { useAccount, useReadContracts } from "wagmi";
import { CONTRACTS, GATEWAY_ABI } from "../config/contracts.js";
import { ACTIVE_CHAIN_ID } from "../lib/appkit.js";
import { money } from "../lib/format.js";
import { reason, send } from "../lib/tx.js";
import { Sheet, useUi } from "./Ui.jsx";

const DENOMINATIONS = [20, 40, 60, 80, 100]; // gateway default withdrawalDenominations
const FEE_BPS = 1000; // gateway default withdrawal_fee

function NotLive() {
  return (
    <div className="alert alert-info alert-sm mt-3">
      <CircleAlert className="size-5 shrink-0" /><span>Available once the contracts are deployed.</span>
    </div>
  );
}

const toWei = (text) => {
  try { return parseUnits(text || "0", 18); } catch { return null; }
};

export function DepositSheet() {
  const { sheet, openSheet, toast } = useUi();
  const { address } = useAccount();
  const queryClient = useQueryClient();
  const [amount, setAmount] = useState("");
  const [step, setStep] = useState("");
  const [error, setError] = useState("");

  const { data } = useReadContracts({
    contracts: [
      { address: CONTRACTS.usdt, abi: erc20Abi, functionName: "balanceOf", args: [address], chainId: ACTIVE_CHAIN_ID },
      { address: CONTRACTS.usdt, abi: erc20Abi, functionName: "allowance", args: [address, CONTRACTS.gateway], chainId: ACTIVE_CHAIN_ID },
      { address: CONTRACTS.gateway, abi: GATEWAY_ABI, functionName: "minDeposit", chainId: ACTIVE_CHAIN_ID },
    ],
    allowFailure: false,
    query: { enabled: sheet === "deposit" && Boolean(address && CONTRACTS.gateway) },
  });
  const [balance, allowance, minDeposit] = data ?? [];

  const wei = toWei(amount);
  const tooSmall = amount !== "" && minDeposit !== undefined && (wei === null || wei < minDeposit);
  const tooBig = wei !== null && balance !== undefined && wei > balance;
  const ready = amount !== "" && wei > 0n && !tooSmall && !tooBig && balance !== undefined && minDeposit !== undefined && !step;

  const submit = async () => {
    if (!ready) return;
    setError("");
    try {
      if (allowance < wei) {
        setStep("Approve USDT in your wallet…");
        await send({ address: CONTRACTS.usdt, abi: erc20Abi, functionName: "approve", args: [CONTRACTS.gateway, wei] }, address);
      }
      setStep("Confirm your deposit…");
      await send({ address: CONTRACTS.gateway, abi: GATEWAY_ABI, functionName: "deposit", args: [CONTRACTS.usdt, wei] }, address);
      await queryClient.invalidateQueries();
      toast(`${money(wei)} USDT deposited.`);
      setAmount("");
      openSheet(null);
    } catch (err) {
      setError(reason(err));
    }
    setStep("");
  };

  return (
    <Sheet id="deposit" label="Deposit">
      <div className="px-5 pb-1 pt-3">
        <h3 className="text-lg font-extrabold">Deposit</h3>
        <p className="text-[13px] text-muted">USDT is added to your ZYQORIX wallet balance.{minDeposit ? ` Minimum ${money(minDeposit)} USDT.` : ""}</p>
      </div>
      <div className="px-5 pt-3">
        <label className="label" htmlFor="deposit-amount">Amount (USDT)</label>
        <input id="deposit-amount" className="input input-filled" type="number" inputMode="decimal" min="0" placeholder="0.00" value={amount} disabled={Boolean(step)} onChange={(e) => { setAmount(e.target.value); setError(""); }} />
        <p className="mt-2 text-[12.5px] text-muted">Your USDT: {balance === undefined ? "…" : money(balance)}</p>
        {tooSmall && <p className="mt-2 text-[12.5px] font-semibold text-rose-500">The minimum deposit is {money(minDeposit)} USDT.</p>}
        {tooBig && <p className="mt-2 text-[12.5px] font-semibold text-rose-500">You don't have enough USDT.</p>}
        {error && <p className="mt-2 text-[12.5px] font-semibold text-rose-500" role="alert">{error}</p>}
        <p className="mt-2 text-[12.5px] text-muted">Each deposit restarts your withdrawal cooldown.</p>
        <button type="button" className="btn btn-primary btn-block mt-3" disabled={!ready} onClick={submit}>{step || "Deposit"}</button>
        <button type="button" className="btn btn-neutral btn-block mt-2" disabled={Boolean(step)} onClick={() => openSheet(null)}>Close</button>
      </div>
    </Sheet>
  );
}

export function WithdrawSheet() {
  const { openSheet } = useUi();
  const [amount, setAmount] = useState(DENOMINATIONS[0]);
  return (
    <Sheet id="withdraw" label="Withdraw">
      <div className="px-5 pb-1 pt-3">
        <h3 className="text-lg font-extrabold">Withdraw</h3>
        <p className="text-[13px] text-muted">Withdrawals are paid from your rewards.</p>
      </div>
      <div className="px-5 pt-3">
        <p className="label">Amount (USDT)</p>
        <div className="tabs-pills">
          {DENOMINATIONS.map((d) => (
            <button key={d} type="button" className={amount === d ? "is-active" : ""} aria-pressed={amount === d} onClick={() => setAmount(d)}>{d}</button>
          ))}
        </div>
        <p className="mt-3 text-[13px] text-muted">You receive {amount - (amount * FEE_BPS) / 10000} USDT.<br/>{FEE_BPS / 100}% Swap and Burn.</p>
        <NotLive />
        <button type="button" className="btn btn-primary btn-block mt-3" disabled>Withdraw</button>
        <button type="button" className="btn btn-neutral btn-block mt-2" onClick={() => openSheet(null)}>Close</button>
      </div>
    </Sheet>
  );
}
