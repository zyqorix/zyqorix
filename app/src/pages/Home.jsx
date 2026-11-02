import { ArrowDownToLine, ArrowUpFromLine, Gift, Network } from "lucide-react";
import { Link } from "react-router-dom";
import { useAccount } from "wagmi";
import { ConnectButton } from "../components/ConnectButton.jsx";
import { useUi } from "../components/Ui.jsx";
import { useMember } from "../hooks/useMember.js";
import { useNetwork } from "../hooks/useNetwork.js";

export default function Home() {
  const { openSheet } = useUi();
  const { isConnected } = useAccount();
  const { isMember, isLoading } = useMember();
  const { name, wrongNetwork, appNetwork, switchToApp } = useNetwork();
  return (
    <>
      <section className="bg-mesh shape-curve shape-bubbles relative px-5 pb-16 pt-[calc(var(--header-h)+env(safe-area-inset-top)+12px)] text-white">
        <span className="chip glass mb-4 text-white">{name}</span>
        <h1 className="text-[34px] font-extrabold leading-[1.1] text-balance">Welcome to ZYQORIX.</h1>
        <p className="mt-3 max-w-xs text-[14.5px] leading-relaxed text-white/80">{isConnected ? "Your wallet is connected." : "Connect your wallet to see your balances and your network."}</p>
        {wrongNetwork && (
          <div className="mt-4">
            <p className="text-[13px] font-semibold">Your wallet is on {name}. ZYQORIX runs on {appNetwork}.</p>
            <button type="button" className="btn btn-white mt-2" onClick={switchToApp}>Switch to {appNetwork}</button>
          </div>
        )}
        <div className="mt-6 flex flex-wrap items-center gap-2.5">
          <ConnectButton />
          {isConnected && !isMember && !isLoading && <Link to="/register" className="btn btn-white">Register</Link>}
        </div>
      </section>

      <section className="relative z-10 -mt-10 px-4">
        <div className="card grid grid-cols-2 divide-x divide-line py-4 text-center">
          <div><p className="text-2xl font-extrabold">—</p><p className="text-[11.5px] font-semibold text-muted">Wallet</p></div>
          <div><p className="text-2xl font-extrabold">—</p><p className="text-[11.5px] font-semibold text-muted">Directs</p></div>
        </div>
      </section>

      {isMember && <section className="section pt-6">
        <div className="grid grid-cols-4 gap-3 text-center text-[11.5px] font-semibold">
          <button type="button" className="tap-scale flex flex-col items-center gap-2" onClick={() => openSheet("deposit")}><span className="icon-box icon-box-lg"><ArrowDownToLine className="size-5" /></span>Deposit</button>
          <button type="button" className="tap-scale flex flex-col items-center gap-2" onClick={() => openSheet("withdraw")}><span className="icon-box icon-box-lg bg-emerald-500/12 text-emerald-500"><ArrowUpFromLine className="size-5" /></span>Withdraw</button>
          <Link to="/network" className="tap-scale flex flex-col items-center gap-2"><span className="icon-box icon-box-lg bg-sky-500/12 text-sky-500"><Network className="size-5" /></span>Network</Link>
          <Link to="/rewards" className="tap-scale flex flex-col items-center gap-2"><span className="icon-box icon-box-lg bg-amber-500/12 text-amber-500"><Gift className="size-5" /></span>Rewards</Link>
        </div>
      </section>}
    </>
  );
}
