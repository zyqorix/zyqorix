// Web3 config: Reown AppKit + wagmi adapter. Imported once (side effect) from main.jsx.
// See templates/web3-integration-template.md and templates/local-chain-template.md.
import { createAppKit } from "@reown/appkit/react";
import { WagmiAdapter } from "@reown/appkit-adapter-wagmi";
import { bsc, defineChain } from "@reown/appkit/networks";

// A public client identifier, safe in the frontend. Falls back to the shared dev id.
const projectId = import.meta.env.VITE_REOWN_PROJECT_ID || "3114629b3157317b0cf3be442a510ede";

// Shared NAS anvil. In dev the browser reads through the same-origin Vite /rpc proxy, because Chrome
// Private Network Access blocks a localhost page calling the NAS private IP directly.
const anvil = defineChain({
  id: 31337,
  caipNetworkId: "eip155:31337",
  chainNamespace: "eip155",
  name: "Anvil",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [import.meta.env.DEV ? `${window.location.origin}/rpc` : "https://rpc-testnet.orbix.onl"] } },
  testnet: true,
});

// One network per build: with several, wagmi reads default to the first when the wallet hasn't synced.
const NETWORKS = { anvil, bsc };
export const network = NETWORKS[import.meta.env.VITE_NETWORK] || (import.meta.env.DEV ? anvil : bsc);
const networks = [network];

export const ACTIVE_CHAIN_ID = network.id;
/** Anvil mines only when a transaction arrives, so on a quiet node the latest block's clock stands still.
 *  Time-gated reads and gas estimates use the pending block there, which carries the current time. */
export const BLOCK_TAG = ACTIVE_CHAIN_ID === 31337 ? "pending" : "latest";

const wagmiAdapter = new WagmiAdapter({ networks, projectId, ssr: false });
export const wagmiConfig = wagmiAdapter.wagmiConfig;

export const appKit = createAppKit({
  adapters: [wagmiAdapter],
  networks,
  defaultNetwork: network,
  projectId,
  metadata: {
    name: "ZYQORIX",
    description: "ZYQORIX on BNB Chain.",
    url: window.location.origin,
    icons: [`${window.location.origin}/icon.svg`],
  },
  features: { analytics: false, email: false, socials: false },
});
