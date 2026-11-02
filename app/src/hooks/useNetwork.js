import { useAccount } from "wagmi";
import { ACTIVE_CHAIN_ID, appKit, network } from "../lib/appkit.js";

// A wallet can sit on any chain, so these names cover chains outside the app's own config.
const CHAIN_NAMES = {
  1: "Ethereum",
  10: "Optimism",
  56: "BNB Chain",
  97: "BNB Testnet",
  137: "Polygon",
  8453: "Base",
  42161: "Arbitrum",
  43114: "Avalanche",
  31337: "Anvil",
};

/** The connected wallet's network, or the app's own network while disconnected. */
export function useNetwork() {
  const { isConnected, chainId } = useAccount();
  const id = isConnected && chainId ? chainId : ACTIVE_CHAIN_ID;
  return {
    name: CHAIN_NAMES[id] || `Chain ${id}`,
    appNetwork: CHAIN_NAMES[ACTIVE_CHAIN_ID],
    wrongNetwork: id !== ACTIVE_CHAIN_ID,
    switchToApp: () => appKit.switchNetwork(network),
  };
}
