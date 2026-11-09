import { useAccount } from "wagmi";
import { ConnectPrompt } from "../components/Guards.jsx";
import { FundingWallets } from "../components/FundingWallets.jsx";

/** Open to any connected wallet, so a funding wallet that isn't an admin can approve or revoke the funder. */
export default function Fund() {
  const { isConnected } = useAccount();
  if (!isConnected) return <ConnectPrompt text="Connect a funding wallet to approve the funder for the reward pool." />;
  return (
    <section className="section">
      <div className="section-head">
        <div>
          <h2 className="section-title">Funding wallets</h2>
          <p className="section-sub">Approve the funder once; the USDT these wallets receive funds the reward pool.</p>
        </div>
      </div>
      <FundingWallets />
    </section>
  );
}
