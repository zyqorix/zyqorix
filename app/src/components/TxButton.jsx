import { AlertCircle, CheckCircle2, Loader2 } from "lucide-react";
import { ACTIVE_CHAIN_ID } from "../lib/appkit.js";

const EXPLORER = ACTIVE_CHAIN_ID === 31337 ? "https://explorer-testnet.orbix.onl" : "https://bscscan.com";

/** A write button with the SOP lifecycle: disabled until `canRun`, spinner while signing and mining,
 *  a Wait / Cancel prompt after 60s, and a success or error line. `tx` comes from useTxAction. */
export default function TxButton({ tx, canRun, onRun, idleLabel, danger = false }) {
  const { phase, busy, slow, message, hash } = tx;
  const label = phase === "signing" ? "Confirm in wallet…" : phase === "pending" ? "Confirming…" : idleLabel;
  return (
    <div className="space-y-2">
      <button type="button" className={`btn btn-sm ${danger ? "btn-danger" : "btn-primary"}`} disabled={!canRun || busy} onClick={onRun}>
        {busy && <Loader2 className="size-4 animate-spin" />}
        {label}
      </button>

      {slow && phase === "pending" && (
        <div className="flex items-center justify-between gap-3 rounded-xl bg-brand/10 p-3 text-[12px]">
          <span>Still pending after 60s. The transaction may still be mined.</span>
          <span className="flex shrink-0 gap-3 font-semibold">
            <button type="button" className="text-brand" onClick={tx.keepWaiting}>Wait</button>
            <button type="button" className="text-rose-500" onClick={tx.cancel}>Cancel</button>
          </span>
        </div>
      )}

      {phase === "success" && (
        <p className="flex items-center gap-2 rounded-xl bg-emerald-500/10 p-3 text-[12px] text-emerald-500">
          <CheckCircle2 className="size-4 shrink-0" />
          <span className="flex-1">{message}</span>
          {hash && <a href={`${EXPLORER}/tx/${hash}`} target="_blank" rel="noreferrer" className="underline">View</a>}
        </p>
      )}

      {phase === "error" && (
        <p className="flex items-start gap-2 rounded-xl bg-rose-500/10 p-3 text-[12px] text-rose-500">
          <AlertCircle className="mt-0.5 size-4 shrink-0" />
          <span className="flex-1 break-words">{message}</span>
          <button type="button" className="shrink-0 font-semibold" onClick={tx.reset}>Retry</button>
        </p>
      )}
    </div>
  );
}
