import { useEffect, useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { erc20Abi, parseUnits } from "viem";
import { useAccount, useReadContract, useReadContracts } from "wagmi";
import { CONTRACTS, GATEWAY_ABI, REWARDS_ABI } from "../config/contracts.js";
import { ACTIVE_CHAIN_ID } from "../lib/appkit.js";
import { money } from "../lib/format.js";
import { ensureAllowance, reason, send } from "../lib/tx.js";
import { Sheet, useUi } from "./Ui.jsx";


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
      { address: CONTRACTS.gateway, abi: GATEWAY_ABI, functionName: "minDeposit", chainId: ACTIVE_CHAIN_ID },
    ],
    allowFailure: false,
    query: { enabled: sheet === "deposit" && Boolean(address && CONTRACTS.gateway) },
  });
  const [balance, minDeposit] = data ?? [];

  const wei = toWei(amount);
  const tooSmall = amount !== "" && minDeposit !== undefined && (wei === null || wei < minDeposit);
  const tooBig = wei !== null && balance !== undefined && wei > balance;
  const ready = amount !== "" && wei > 0n && !tooSmall && !tooBig && balance !== undefined && minDeposit !== undefined && !step;

  const submit = async () => {
    if (!ready) return;
    setError("");
    try {
      setStep("Approve USDT in your wallet…");
      await ensureAllowance(CONTRACTS.usdt, CONTRACTS.gateway, wei, address);
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

/** Amounts the gateway accepts: withdrawalMin to withdrawalMax in steps of withdrawalStep (20 … 100 by default). */
function allowedAmounts(min, max, step) {
  if (!min || !max || !step || step === 0n) return [];
  const list = [];
  for (let a = min; a <= max && list.length < 50; a += step) list.push(a);
  return list;
}

function waitText(seconds) {
  if (seconds < 90) return `${seconds}s`;
  if (seconds < 5400) return `${Math.ceil(seconds / 60)}m`;
  return `${Math.ceil(seconds / 3600)}h`;
}

export function WithdrawSheet() {
  const { sheet, openSheet, toast } = useUi();
  const { address } = useAccount();
  const queryClient = useQueryClient();
  const [amount, setAmount] = useState(null);
  const [step, setStep] = useState("");
  const [error, setError] = useState("");
  const [, setTick] = useState(0);

  // Re-render every second while open so the cooldown countdown moves.
  useEffect(() => {
    if (sheet !== "withdraw") return undefined;
    const id = setInterval(() => setTick((t) => t + 1), 1000);
    return () => clearInterval(id);
  }, [sheet]);

  const gateway = { address: CONTRACTS.gateway, abi: GATEWAY_ABI, chainId: ACTIVE_CHAIN_ID };
  const { data } = useReadContracts({
    contracts: [
      { ...gateway, functionName: "withdrawalMin" },
      { ...gateway, functionName: "withdrawalMax" },
      { ...gateway, functionName: "withdrawalStep" },
      { ...gateway, functionName: "withdrawal_fee" },
      { ...gateway, functionName: "coolDown", args: [address] },
      { address: CONTRACTS.rewards, abi: REWARDS_ABI, functionName: "getUser", args: [address], chainId: ACTIVE_CHAIN_ID },
    ],
    allowFailure: false,
    query: { enabled: sheet === "withdraw" && Boolean(address && CONTRACTS.gateway), refetchInterval: 5_000 },
  });
  const [min, max, stepSize, feeBps, coolDown, user] = data ?? [];
  // Daily and generation rewards leave only through the funded reward pool. Contracts without `withdrawable`
  // (before 2026-11-04) have no such limit, so a failed read falls back to the wallet balance.
  const { data: payable } = useReadContract({
    address: CONTRACTS.rewards, abi: REWARDS_ABI, functionName: "withdrawable", args: [address], chainId: ACTIVE_CHAIN_ID,
    query: { enabled: sheet === "withdraw" && Boolean(address), refetchInterval: 5_000, retry: false },
  });
  const amounts = allowedAmounts(min, max, stepSize);
  const wallet = user?.walletBalance;
  const available = payable ?? wallet;
  const waiting = wallet !== undefined && available !== undefined && available < wallet;
  const wait = coolDown === undefined ? 0 : Math.max(0, Math.ceil(Number(coolDown) - Date.now() / 1000));
  const chosen = amount !== null && amounts.some((a) => a === amount) ? amount : null;
  const fee = chosen !== null && feeBps !== undefined ? (chosen * feeBps) / 10000n : 0n;
  const ready = chosen !== null && available !== undefined && chosen <= available && wait === 0 && !step;

  const submit = async () => {
    if (!ready) return;
    setError("");
    try {
      setStep("Confirm your withdrawal…");
      // The fee swap and burn runs in a try/catch, so the wallet estimate can settle on a limit where it runs out of
      // gas and the fee is kept instead of burned. A short reward pool also pulls the funding wallets first (up to 5)
      // before that check. 1.1M covers both; only the gas actually used is paid.
      await send({ ...gateway, functionName: "withdraw", args: [chosen] }, address, { minGas: 1_100_000n });
      await queryClient.invalidateQueries();
      toast(`${money(chosen - fee)} USDT sent to your wallet.`);
      setAmount(null);
      openSheet(null);
    } catch (err) {
      setError(reason(err));
    }
    setStep("");
  };

  return (
    <Sheet id="withdraw" label="Withdraw">
      <div className="px-5 pb-1 pt-3">
        <h3 className="text-lg font-extrabold">Withdraw</h3>
        <p className="text-[13px] text-muted">
          From your wallet balance{min !== undefined ? `: ${money(min)} to ${money(max)} USDT in steps of ${money(stepSize)}` : ""}.
        </p>
      </div>
      <div className="px-5 pt-3">
        <p className="label">Amount (USDT)</p>
        <div className="tabs-pills flex-wrap">
          {amounts.map((a) => (
            <button key={a.toString()} type="button" className={chosen === a ? "is-active" : ""} aria-pressed={chosen === a}
              disabled={Boolean(step) || available === undefined || a > available} onClick={() => { setAmount(a); setError(""); }}>{money(a)}</button>
          ))}
        </div>
        <p className="mt-2 text-[12.5px] text-muted">Wallet balance: {wallet === undefined ? "…" : `${money(wallet)} USDT`}</p>
        {waiting && (
          <p className="mt-2 text-[12.5px] font-semibold text-amber-500" role="note">
            Available to withdraw now: {money(available)} USDT. The other {money(wallet - available)} USDT is daily and generation rewards, paid from the reward pool, which is waiting for funding.
          </p>
        )}
        {wallet !== undefined && min !== undefined && wallet < min && (
          <p className="mt-2 text-[12.5px] font-semibold text-amber-500">You need at least {money(min)} USDT in your wallet balance to withdraw.</p>
        )}
        {chosen !== null && feeBps !== undefined && (
          <p className="mt-2 text-[13px] text-muted">You receive {money(chosen - fee)} USDT. {Number(feeBps) / 100}% goes to Swap and Burn.</p>
        )}
        {wait > 0 && <p className="mt-2 text-[12.5px] font-semibold text-amber-500">Your withdrawal cooldown ends in about {waitText(wait)}.</p>}
        {error && <p className="mt-2 text-[12.5px] font-semibold text-rose-500" role="alert">{error}</p>}
        <button type="button" className="btn btn-primary btn-block mt-3" disabled={!ready} onClick={submit}>{step || "Withdraw"}</button>
        <button type="button" className="btn btn-neutral btn-block mt-2" disabled={Boolean(step)} onClick={() => openSheet(null)}>Close</button>
      </div>
    </Sheet>
  );
}
