import { useAppKit } from "@reown/appkit/react";
import { ArrowDownToLine, ArrowLeftRight, ArrowUpFromLine, BookOpen, Bot, CircleHelp, Gamepad2, Gift, Hourglass, Info, Network, Unplug, WalletMinimal } from "lucide-react";
import { Link } from "react-router-dom";
import { useAccount, useDisconnect } from "wagmi";
import { useUi } from "../components/Ui.jsx";
import { useMember } from "../hooks/useMember.js";
import { useNetwork } from "../hooks/useNetwork.js";

// Home shortcuts: members see all of them, visitors only the public About pages. Every icon box uses the accent colour picked in the drawer.
const SHORTCUTS = [
  { label: "Deposit", icon: ArrowDownToLine, sheet: "deposit" },
  { label: "Withdraw", icon: ArrowUpFromLine, sheet: "withdraw" },
  { label: "Network", icon: Network, to: "/network" },
  { label: "Rewards", icon: Gift, to: "/rewards" },
  { label: "Vesting", icon: Hourglass, to: "/vesting" },
  { label: "Swap", icon: ArrowLeftRight, to: "/swap" },
  { label: "Bot", icon: Bot, to: "/bot" },
  { label: "Games", icon: Gamepad2, to: "/games" },
  { label: "About", icon: Info, to: "/about", isPublic: true },
  { label: "Rewards Plan", icon: BookOpen, to: "/about/rewardsplan", isPublic: true },
  { label: "FAQ", icon: CircleHelp, to: "/about/faq", isPublic: true },
];

/** Connect / disconnect as a chip beside the network label. The wallet address is never shown on Home. */
function WalletChip() {
  const { isConnected } = useAccount();
  const { open } = useAppKit();
  const { disconnect } = useDisconnect();
  if (isConnected) {
    return (
      <button type="button" className="chip glass tap-scale text-white" onClick={() => disconnect()} aria-label="Disconnect wallet" title="Disconnect wallet">
        <Unplug className="size-4" />
      </button>
    );
  }
  return (
    <button type="button" className="chip glass tap-scale gap-1.5 text-white" onClick={() => open()}>
      <WalletMinimal className="size-4" />
      Connect
    </button>
  );
}

export default function Home() {
  const { openSheet } = useUi();
  const { isConnected } = useAccount();
  const { isMember, isLoading } = useMember();
  const { name, wrongNetwork, appNetwork, switchToApp } = useNetwork();
  const shortcuts = SHORTCUTS.filter((s) => isMember || s.isPublic);
  return (
    <>
      <section className="bg-mesh shape-curve shape-bubbles relative px-5 pb-16 pt-[calc(var(--header-h)+env(safe-area-inset-top)+12px)] text-white">
        <div className="mb-4 flex items-center gap-2">
          <span className="chip glass text-white">{name}</span>
          <WalletChip />
        </div>
        <h1 className="text-[34px] font-extrabold leading-[1.1] text-balance">Welcome to ZYQORIX.</h1>
        <p className="mt-3 max-w-xs text-[14.5px] leading-relaxed text-white/80">{isConnected ? "Your wallet is connected." : "Connect your wallet to see your balances and your network."}</p>
        <p className="mt-3 max-w-xs text-[14.5px] leading-relaxed text-white/80"><strong>What is your money doing</strong><br/> while you are sleeping?</p>
        {wrongNetwork && (
          <div className="mt-4">
            <p className="text-[13px] font-semibold">Your wallet is on {name}. ZYQORIX runs on {appNetwork}.</p>
            <button type="button" className="btn btn-white mt-2" onClick={switchToApp}>Switch to {appNetwork}</button>
          </div>
        )}
        {isConnected && !isMember && !isLoading && <div className="mt-6"><Link to="/register" className="btn btn-white">Register</Link></div>}
      </section>

      <section className="relative z-10 -mt-10 px-4">
        <div className="card grid grid-cols-2 divide-x divide-line py-4 text-center">
          <div><p className="text-2xl font-extrabold">—</p><p className="text-[11.5px] font-semibold text-muted">Wallet</p></div>
          <div><p className="text-2xl font-extrabold">—</p><p className="text-[11.5px] font-semibold text-muted">Directs</p></div>
        </div>
      </section>

      <section className="section pt-6">
        <div className="grid grid-cols-4 gap-3 text-center text-[11.5px] font-semibold">
          {shortcuts.map(({ label, icon: Icon, to, sheet }) => {
            const body = <><span className="icon-box icon-box-lg bg-brand text-white shadow-glow"><Icon className="size-5" /></span>{label}</>;
            return sheet
              ? <button key={label} type="button" className="tap-scale flex flex-col items-center gap-2" onClick={() => openSheet(sheet)}>{body}</button>
              : <Link key={label} to={to} className="tap-scale flex flex-col items-center gap-2">{body}</Link>;
          })}
        </div>
      </section>
    </>
  );
}
