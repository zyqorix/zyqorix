import { ArrowDownToLine, ArrowUpFromLine } from "lucide-react";
import { useAccount, useReadContract } from "wagmi";
import { useUi } from "../components/Ui.jsx";
import { CONTRACTS, REWARDS_ABI } from "../config/contracts.js";
import { ACTIVE_CHAIN_ID } from "../lib/appkit.js";
import { money } from "../lib/format.js";

export default function Wallet() {
  const { openSheet } = useUi();
  const { address } = useAccount();
  const { data: user } = useReadContract({
    address: CONTRACTS.rewards,
    abi: REWARDS_ABI,
    functionName: "getUser",
    args: [address],
    chainId: ACTIVE_CHAIN_ID,
    query: { enabled: Boolean(address && CONTRACTS.rewards) },
  });
  return (
    <>
      <section className="section">
        <div className="card card-gradient shape-bubbles p-5">
          <p className="text-[13px] font-semibold text-white/80">Wallet balance</p>
          <p className="mt-1 text-[34px] font-extrabold leading-none">{user ? money(user.walletBalance) : "—"} <span className="text-base font-bold">USDT</span></p>
          <div className="mt-5 grid grid-cols-2 gap-2.5">
            <button type="button" className="btn btn-white" onClick={() => openSheet("deposit")}><ArrowDownToLine className="size-5" />Deposit</button>
            <button type="button" className="btn glass text-white" onClick={() => openSheet("withdraw")}><ArrowUpFromLine className="size-5" />Withdraw</button>
          </div>
        </div>
      </section>
    </>
  );
}
