import { useCallback, useEffect, useRef, useState } from "react";
import { getPublicClient } from "wagmi/actions";
import { useAccount, useWaitForTransactionReceipt, useWriteContract } from "wagmi";
import { ACTIVE_CHAIN_ID, BLOCK_TAG, wagmiConfig } from "../lib/appkit.js";
import { reason } from "../lib/tx.js";

const WAIT_MS = 60_000; // wait this long before offering Cancel / Keep waiting

/** One write's lifecycle, per references/sops/smart-contract-integration.md:
 *  idle → signing → pending → success | error, plus a `slow` flag after 60s in pending.
 *  Gas gets a 30% margin, as in lib/tx.js: anvil's block time can make estimates low. */
export function useTxAction() {
  const { address } = useAccount();
  const { writeContractAsync, reset: resetWrite } = useWriteContract();
  const [hash, setHash] = useState(undefined);
  const [phase, setPhase] = useState("idle");
  const [message, setMessage] = useState("");
  const [slow, setSlow] = useState(false);
  const timer = useRef(null);

  const { data: receipt, isError, error } = useWaitForTransactionReceipt({
    hash, chainId: ACTIVE_CHAIN_ID, query: { enabled: Boolean(hash) },
  });

  const stopTimer = () => { if (timer.current) clearTimeout(timer.current); timer.current = null; };
  const armTimer = useCallback(() => {
    stopTimer();
    setSlow(false);
    timer.current = setTimeout(() => setSlow(true), WAIT_MS);
  }, []);

  useEffect(() => {
    if (!hash) return;
    if (receipt) {
      stopTimer();
      if (receipt.status === "success") { setPhase("success"); setMessage("Transaction confirmed."); }
      else { setPhase("error"); setMessage("The transaction reverted on-chain."); }
    } else if (isError) {
      stopTimer();
      setPhase("error");
      setMessage(reason(error));
    }
  }, [receipt, isError, error, hash]);

  useEffect(() => () => stopTimer(), []);

  /** config = { address, abi, functionName, args } */
  const run = useCallback(async (config) => {
    setMessage("");
    setSlow(false);
    setHash(undefined);
    setPhase("signing");
    try {
      const client = getPublicClient(wagmiConfig, { chainId: ACTIVE_CHAIN_ID });
      const gas = await client.estimateContractGas({ ...config, account: address, blockTag: BLOCK_TAG });
      const h = await writeContractAsync({ ...config, chainId: ACTIVE_CHAIN_ID, gas: (gas * 13n) / 10n });
      setHash(h);
      setPhase("pending");
      armTimer();
    } catch (e) {
      stopTimer();
      setPhase("error");
      setMessage(reason(e));
    }
  }, [address, writeContractAsync, armTimer]);

  const reset = useCallback(() => {
    stopTimer();
    setHash(undefined);
    setPhase("idle");
    setMessage("");
    setSlow(false);
    resetWrite();
  }, [resetWrite]);

  const busy = phase === "signing" || phase === "pending";
  // Cancel only stops tracking: the transaction may still be mined.
  return { phase, busy, slow, message, hash, run, reset, keepWaiting: armTimer, cancel: reset };
}
