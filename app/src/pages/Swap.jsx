import { useState } from "react";
import { ArrowDown } from "lucide-react";
import { useQueryClient } from "@tanstack/react-query";
import { erc20Abi, parseEther } from "viem";
import { useAccount, useReadContract, useReadContracts } from "wagmi";
import { ConnectButton } from "../components/ConnectButton.jsx";
import { useUi } from "../components/Ui.jsx";
import liquidityAbi from "../config/abi/liquidity.json";
import { CONTRACTS } from "../config/contracts.js";
import { ACTIVE_CHAIN_ID, BLOCK_TAG } from "../lib/appkit.js";
import { money } from "../lib/format.js";
import { ensureAllowance, reason, send } from "../lib/tx.js";

const chainId = ACTIVE_CHAIN_ID;
const liquidity = { address: CONTRACTS.liquidity, abi: liquidityAbi, chainId };
const SLIPPAGE = [100, 300, 500, 1000]; // bps, picked by hand; "Auto" sizes it from the live quote
const DEADLINE = 20 * 60; // seconds
const BUFFER = 50; // bps added to the measured shortfall, so a block of price movement doesn't fail the swap
// PancakeSwap V3 QuoterV2: what the pool really pays, after its fee and this swap's price impact. Anvil's
// stand-in router pays the TWAP rate exactly, so it needs no quoter.
const QUOTER = { 56: "0xB048Bbc1Ee6b733FFfCFb9e9CeF7375518e25997" }[chainId];
const QUOTER_ABI = [{
  type: "function", name: "quoteExactInputSingle", stateMutability: "view",
  inputs: [{ name: "params", type: "tuple", components: [
    { name: "tokenIn", type: "address" }, { name: "tokenOut", type: "address" }, { name: "amountIn", type: "uint256" },
    { name: "fee", type: "uint24" }, { name: "sqrtPriceLimitX96", type: "uint160" },
  ] }],
  outputs: [{ name: "amountOut", type: "uint256" }, { name: "sqrtPriceX96After", type: "uint160" }, { name: "initializedTicksCrossed", type: "uint32" }, { name: "gasEstimate", type: "uint256" }],
}];

function parse(text) {
  try { return text ? parseEther(text) : 0n; } catch { return null; }
}

/** Buy ZQR with USDT through the liquidity contract. The contract's minimum out is the 30-minute TWAP minus the
 *  slippage, and the TWAP leaves out the pool fee and the swap's own price impact, so on a thin pool a small
 *  slippage always fails ("Too little received"). The live quote measures that gap and Auto covers it. */
export default function Swap() {
  const { address, isConnected } = useAccount();
  const { toast } = useUi();
  const queryClient = useQueryClient();
  const [text, setText] = useState("");
  const [manual, setManual] = useState(null); // bps, or null for Auto
  const [step, setStep] = useState("");
  const [error, setError] = useState("");

  const wei = parse(text);
  const { data } = useReadContracts({
    contracts: [
      { address: CONTRACTS.usdt, abi: erc20Abi, functionName: "balanceOf", args: [address], chainId },
      { address: CONTRACTS.zqr, abi: erc20Abi, functionName: "balanceOf", args: [address], chainId },
      { address: CONTRACTS.usdt, abi: erc20Abi, functionName: "allowance", args: [address, CONTRACTS.liquidity], chainId },
    ],
    allowFailure: false,
    blockTag: BLOCK_TAG,
    query: { enabled: Boolean(address && CONTRACTS.liquidity), refetchInterval: 15_000 },
  });
  const [usdt, zqr, allowance] = data ?? [];

  // Price of 1 USDT, and the quote for the typed amount. Both revert until the pool's TWAP is ready.
  const price = useReadContract({ ...liquidity, functionName: "convertToken", args: [CONTRACTS.usdt, parseEther("1")], blockTag: BLOCK_TAG, query: { enabled: Boolean(CONTRACTS.liquidity), refetchInterval: 30_000 } });
  const quote = useReadContract({ ...liquidity, functionName: "convertToken", args: [CONTRACTS.usdt, wei || 0n], blockTag: BLOCK_TAG, query: { enabled: Boolean(CONTRACTS.liquidity && wei) } });
  const { data: fee } = useReadContract({ ...liquidity, functionName: "FEE", query: { enabled: Boolean(CONTRACTS.liquidity && QUOTER) } });
  const live = useReadContract({
    address: QUOTER, abi: QUOTER_ABI, functionName: "quoteExactInputSingle", chainId,
    args: [{ tokenIn: CONTRACTS.usdt, tokenOut: CONTRACTS.zqr, amountIn: wei || 0n, fee: fee ?? 0, sqrtPriceLimitX96: 0n }],
    query: { enabled: Boolean(QUOTER && wei && fee !== undefined), refetchInterval: 15_000, retry: false },
  });
  // If the quoter can't be read, fall back to the TWAP quote: the page still works, Auto just can't size the gap.
  const received = QUOTER && !live.isError ? live.data?.[0] : quote.data;
  // How far below the TWAP the pool really pays, in bps, rounded up.
  const gap = quote.data && received !== undefined && received < quote.data
    ? Number(((quote.data - received) * 10_000n + quote.data - 1n) / quote.data) : 0;
  const needed = Math.min(5_000, gap + BUFFER);
  const slippage = manual ?? Math.max(100, needed);
  const minOut = quote.data ? (quote.data * BigInt(10_000 - slippage)) / 10_000n : 0n;
  const tooLow = Boolean(wei && received !== undefined && slippage < needed);

  const busy = Boolean(step);
  const problem = wei === null ? "Enter a valid amount."
    : usdt !== undefined && wei > usdt ? "You don't have that much USDT."
    : price.isError ? "The token price isn't available yet."
    : needed >= 5_000 ? "This amount moves the pool too far. Try a smaller swap."
    : tooLow ? `The pool pays ${(gap / 100).toFixed(2)}% below the average price for this amount. Choose at least ${(needed / 100).toFixed(1)}% slippage, use Auto, or swap less.`
    : "";

  const swap = async () => {
    setError("");
    try {
      setStep("Approve USDT…");
      await ensureAllowance(CONTRACTS.usdt, CONTRACTS.liquidity, wei, address);
      setStep("Confirm swap…");
      const deadline = BigInt(Math.floor(Date.now() / 1000) + DEADLINE);
      await send({ ...liquidity, functionName: "swapUSDTToToken", args: [wei, slippage, address, deadline] }, address);
      await queryClient.invalidateQueries();
      setText("");
      toast("Swap complete. The ZQR is in your wallet.");
    } catch (err) {
      setError(reason(err));
    }
    setStep("");
  };

  if (!CONTRACTS.liquidity) return <section className="section"><div className="card card-body text-center"><p className="text-[13px] text-muted">Swap isn't available on this network yet.</p></div></section>;

  return (
    <section className="section">
      <div className="section-head"><div>
        <h2 className="section-title">Swap</h2>
        <p className="section-sub">Buy ZQR with USDT at the pool price.</p>
      </div></div>

      <div className="tabs-pills mb-3">
        <button type="button" className="is-active" aria-pressed="true">Buy ZQR</button>
        <button type="button" disabled aria-disabled="true">Sell · soon</button>
      </div>

      <div className="card card-body space-y-2">
        <div className="rounded-2xl bg-brand/5 p-3">
          <div className="flex justify-between text-[11.5px] font-semibold text-muted">
            <span>You pay</span>
            {usdt !== undefined && <button type="button" className="text-brand" onClick={() => setText((Math.floor(Number(usdt / 10n ** 16n)) / 100).toString())}>Balance {money(usdt)}</button>}
          </div>
          <div className="mt-1 flex items-center gap-2">
            <input className="min-w-0 flex-1 bg-transparent text-2xl font-extrabold outline-none" inputMode="decimal" placeholder="0" aria-label="USDT amount"
              value={text} disabled={busy} onChange={(e) => setText(e.target.value.replace(/[^0-9.]/g, ""))} />
            <span className="chip chip-soft">USDT</span>
          </div>
        </div>

        <div className="flex justify-center"><span className="icon-box icon-box-sm bg-brand text-white"><ArrowDown /></span></div>

        <div className="rounded-2xl bg-brand/5 p-3">
          <div className="flex justify-between text-[11.5px] font-semibold text-muted">
            <span>You receive about</span>
            {zqr !== undefined && <span>Balance {money(zqr)}</span>}
          </div>
          <div className="mt-1 flex items-center gap-2">
            <p className="min-w-0 flex-1 truncate text-2xl font-extrabold">{wei ? money(received) : "0"}</p>
            <span className="chip chip-soft">ZQR</span>
          </div>
        </div>

        <div className="space-y-1.5 pt-1 text-[12.5px]">
          <div className="flex justify-between"><span className="text-muted">Average price (30 min)</span><span className="font-semibold">{price.data ? `1 USDT = ${money(price.data)} ZQR` : "—"}</span></div>
          {QUOTER && wei ? <div className="flex justify-between"><span className="text-muted">Pool fee and price impact</span><span className="font-semibold">{received === undefined ? "…" : `${(gap / 100).toFixed(2)}%`}</span></div> : null}
          <div className="flex items-center justify-between gap-2">
            <span className="text-muted">Slippage</span>
            <span className="flex flex-wrap justify-end gap-1">
              <button type="button" className={`chip ${manual === null ? "bg-brand text-white" : "chip-soft"}`} disabled={busy} onClick={() => setManual(null)}>Auto{manual === null && wei ? ` ${(slippage / 100).toFixed(1)}%` : ""}</button>
              {SLIPPAGE.map((bps) => (
                <button key={bps} type="button" className={`chip ${manual === bps ? "bg-brand text-white" : "chip-soft"}`} disabled={busy} onClick={() => setManual(bps)}>{bps / 100}%</button>
              ))}
            </span>
          </div>
          <div className="flex justify-between"><span className="text-muted">Minimum received</span><span className="font-semibold">{wei ? `${money(minOut)} ZQR` : "—"}</span></div>
        </div>

        {(problem || error) && <p className="text-center text-[12.5px] font-semibold text-rose-500" role="alert">{error || problem}</p>}

        {isConnected
          ? <button type="button" className="btn btn-primary w-full" disabled={busy || !wei || Boolean(problem) || !quote.data || received === undefined} onClick={swap}>{step || (allowance !== undefined && wei && allowance < wei ? "Approve and swap" : "Swap")}</button>
          : <div className="flex justify-center"><ConnectButton /></div>}
      </div>
    </section>
  );
}
