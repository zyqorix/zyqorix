import { WalletMinimal } from "lucide-react";
import { useAccount } from "wagmi";
import { Navigate, Outlet, useLocation } from "react-router-dom";
import { useIsAdmin } from "../hooks/useIsAdmin.js";
import { useMember } from "../hooks/useMember.js";
import { ConnectButton } from "./ConnectButton.jsx";

export function Checking() {
  return <section className="section"><p className="text-center text-[13px] text-muted">Checking your wallet…</p></section>;
}

export function ConnectPrompt({ text = "This page is only available to a connected wallet." }) {
  return (
    <section className="section">
      <div className="card card-body flex flex-col items-center gap-3 text-center">
        <span className="icon-box icon-box-lg"><WalletMinimal className="size-5" /></span>
        <h2 className="text-lg font-extrabold">Connect your wallet</h2>
        <p className="text-[13px] text-muted">{text}</p>
        <ConnectButton />
      </div>
    </section>
  );
}

/** Shows the page only to a registered member. A connected wallet that isn't one goes to Register. */
export function RequireMember() {
  const { isConnected, isConnecting, isReconnecting } = useAccount();
  const { isMember, isLoading, isError, refetch } = useMember();
  const { pathname } = useLocation();
  if (isConnecting || isReconnecting || isLoading) return <Checking />;
  if (!isConnected) return <ConnectPrompt />;
  if (isError) {
    return (
      <section className="section">
        <div className="card card-body text-center">
          <p className="text-[13px] text-muted">We couldn't check your membership. Check your connection and try again.</p>
          <button type="button" className="btn btn-primary btn-block mt-3" onClick={() => refetch()}>Try again</button>
        </div>
      </section>
    );
  }
  if (!isMember) return <Navigate to="/register" replace state={{ from: pathname }} />;
  return <Outlet />;
}

/** Shows the page only to the contract owner or an isAdmin wallet. Anyone else goes home. */
export function RequireAdmin() {
  const { isConnected, isConnecting, isReconnecting } = useAccount();
  const { isAdmin, isLoading } = useIsAdmin();
  if (isConnecting || isReconnecting || isLoading) return <Checking />;
  if (!isConnected || !isAdmin) return <Navigate to="/" replace />;
  return <Outlet />;
}
