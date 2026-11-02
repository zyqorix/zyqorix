import { useAccount, useReadContract } from "wagmi";
import { ACCOUNTS_ABI, CONTRACTS } from "../config/contracts.js";
import { ACTIVE_CHAIN_ID } from "../lib/appkit.js";

/** True for the accounts owner or an isAdmin wallet. The contracts enforce this; the UI only follows it. */
export function useIsAdmin() {
  const { address } = useAccount();
  const enabled = Boolean(address && CONTRACTS.accounts);
  const { data, isLoading } = useReadContract({
    address: CONTRACTS.accounts,
    abi: ACCOUNTS_ABI,
    functionName: "checkIsAdmin",
    args: [address],
    chainId: ACTIVE_CHAIN_ID,
    query: { enabled },
  });
  return { isAdmin: enabled && data === true, isLoading: enabled && isLoading };
}
