import { useMemo } from "react";
import { useReadContracts } from "wagmi";
import { readContract } from "wagmi/actions";
import { ADMIN_CONTRACTS } from "../config/adminContracts.js";
import { ACTIVE_CHAIN_ID, BLOCK_TAG, wagmiConfig } from "../lib/appkit.js";

const isRead = (f) => f.stateMutability === "view" || f.stateMutability === "pure";

/** Everything the admin console needs for one contract, keyed by its slug in config/adminContracts.js.
 *  - `values`: every read with no inputs, loaded together and refreshed every 15s
 *  - `reads` / `writes`: the ABI functions, sorted by name
 *  - `query(fn, args)`: call a read that takes inputs */
export function useAdminContract(slug) {
  const entry = ADMIN_CONTRACTS.find((c) => c.slug === slug);
  const base = entry ? { address: entry.address, abi: entry.abi, chainId: ACTIVE_CHAIN_ID } : null;

  const { reads, writes, plain } = useMemo(() => {
    const fns = (entry?.abi ?? []).filter((x) => x.type === "function").sort((a, b) => a.name.localeCompare(b.name));
    const r = fns.filter(isRead);
    return { reads: r, writes: fns.filter((f) => !isRead(f)), plain: r.filter((f) => f.inputs.length === 0) };
  }, [entry]);

  const state = useReadContracts({
    contracts: base ? plain.map((f) => ({ ...base, functionName: f.name })) : [],
    blockTag: BLOCK_TAG,
    query: { enabled: Boolean(base?.address), refetchInterval: 15_000 },
  });

  const values = {};
  plain.forEach((f, i) => { values[f.name] = state.data?.[i]; });

  const query = (fn, args) => readContract(wagmiConfig, { ...base, functionName: fn.name, args, blockTag: BLOCK_TAG });

  return { entry, base, reads, writes, values, query, refetch: state.refetch, isLoading: state.isLoading };
}
