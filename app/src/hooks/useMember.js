import { useAccount, useReadContract } from "wagmi";
import { ACCOUNTS_ABI, CONTRACTS } from "../config/contracts.js";
import { ACTIVE_CHAIN_ID } from "../lib/appkit.js";

/** Whether the connected wallet is a registered member. `isError` means the check itself failed. */
export function useMember() {
  const { address } = useAccount();
  const enabled = Boolean(address && CONTRACTS.accounts);
  const { data, isLoading, isError, refetch } = useReadContract({
    address: CONTRACTS.accounts,
    abi: ACCOUNTS_ABI,
    functionName: "isUser",
    args: [address],
    chainId: ACTIVE_CHAIN_ID,
    query: { enabled },
  });
  return { isMember: data === true, isLoading: enabled && isLoading, isError: enabled && isError, refetch };
}
