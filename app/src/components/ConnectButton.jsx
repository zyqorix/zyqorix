import { useAppKit } from "@reown/appkit/react";
import { WalletMinimal } from "lucide-react";
import { useAccount } from "wagmi";

/** Opens Reown's connect sheet as a Lumen button. Once connected it shows Reown's account button.
 *  `variant` picks the Lumen style: "white" on the purple hero, "primary" on cards. */
export function ConnectButton({ variant = "primary" }) {
  const { isConnected } = useAccount();
  const { open } = useAppKit();
  if (isConnected) return <appkit-button balance="hide" />;
  return (
    <button type="button" className={`btn btn-${variant}`} onClick={() => open()}>
      <WalletMinimal className="size-5" />
      Connect Wallet
    </button>
  );
}
