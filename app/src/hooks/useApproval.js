import { erc20Abi, isAddress } from "viem";
import { useAccount, useReadContracts } from "wagmi";
import { ADMIN_CONTRACTS, APPROVALS } from "../config/adminContracts.js";
import { CONTRACTS } from "../config/contracts.js";
import { ACTIVE_CHAIN_ID } from "../lib/appkit.js";

const SPENDERS = { gateway: CONTRACTS.gateway };

/** The ERC-20 allowance a console write needs, from APPROVALS in config/adminContracts.js.
 *  Returns null for writes that pull no tokens. `args` may be undefined while the form is incomplete. */
export function useApproval(slug, fn, contractAddress, args) {
  const { address: me } = useAccount();
  const spec = APPROVALS[`${slug}.${fn.name}`];

  const pick = (ref) => (ref && typeof ref === "object" && "arg" in ref ? args?.[ref.arg] : undefined);
  const token = !spec ? undefined : spec.token === "usdt" ? CONTRACTS.usdt : spec.token === "zqr" ? CONTRACTS.zqr : pick(spec.token);
  const payer = !spec ? undefined : spec.payer === "me" ? me : pick(spec.payer);
  const spender = !spec ? undefined : spec.spender === "me" ? me : SPENDERS[spec.spender] ?? contractAddress;
  const readAmount = spec?.amount?.read && ADMIN_CONTRACTS.find((c) => c.slug === spec.amount.read[0]);
  const ready = Boolean(spec && isAddress(token ?? "") && isAddress(payer ?? "") && isAddress(spender ?? ""));

  const { data, refetch, isLoading } = useReadContracts({
    contracts: ready ? [
      { address: token, abi: erc20Abi, functionName: "allowance", args: [payer, spender], chainId: ACTIVE_CHAIN_ID },
      { address: token, abi: erc20Abi, functionName: "balanceOf", args: [payer], chainId: ACTIVE_CHAIN_ID },
      { address: token, abi: erc20Abi, functionName: "symbol", chainId: ACTIVE_CHAIN_ID },
      ...(readAmount ? [{ address: readAmount.address, abi: readAmount.abi, functionName: spec.amount.read[1], chainId: ACTIVE_CHAIN_ID }] : []),
    ] : [],
    query: { enabled: ready },
  });

  if (!spec) return null;
  const amount = readAmount ? data?.[3]?.result : pick(spec.amount);
  const allowance = data?.[0]?.result;
  const balance = data?.[1]?.result;
  return {
    token, payer, spender, amount, allowance, balance,
    symbol: data?.[2]?.result ?? "token",
    payerIsMe: Boolean(me && payer && payer.toLowerCase() === me.toLowerCase()),
    spenderIsMe: spec.spender === "me",
    loading: ready && isLoading,
    ready: ready && typeof amount === "bigint",
    enough: typeof amount === "bigint" && typeof allowance === "bigint" && allowance >= amount,
    covered: typeof amount === "bigint" && typeof balance === "bigint" && balance >= amount,
    refetch,
  };
}
