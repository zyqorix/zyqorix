import { useEffect, useMemo, useState } from "react";
import { Check, X } from "lucide-react";
import { useQueryClient } from "@tanstack/react-query";
import { Navigate, useLocation, useNavigate } from "react-router-dom";
import { erc20Abi, formatUnits, isAddress } from "viem";
import { useAccount, useBalance, useGasPrice, useReadContracts } from "wagmi";
import { Checking, ConnectPrompt } from "../components/Guards.jsx";
import { useUi } from "../components/Ui.jsx";
import { ACCOUNTS_ABI, CONTRACTS, REGISTER_ABI, REWARDS_ABI } from "../config/contracts.js";
import { useMember } from "../hooks/useMember.js";
import { useNetwork } from "../hooks/useNetwork.js";
import { clearStoredSponsor, getStoredSponsor } from "../lib/affiliate.js";
import { ACTIVE_CHAIN_ID } from "../lib/appkit.js";
import { money as usdt } from "../lib/format.js";
import { ensureAllowance, reason, send } from "../lib/tx.js";

const chainId = ACTIVE_CHAIN_ID;
const GAS_SYMBOL = "BNB"; // ZYQORIX runs on BSC; the anvil testnet stands in for it
const GAS_UNITS = 600_000n; // approve plus register, with room to spare

function CheckRow({ ok, label, value }) {
  return (
    <li className="flex items-center gap-2 text-[13px]">
      <span className={`grid size-5 place-items-center rounded-full text-white ${ok ? "bg-emerald-500" : "bg-rose-500"}`}>
        {ok ? <Check className="size-3" /> : <X className="size-3" />}
      </span>
      <span className="flex-1 text-muted">{label}</span>
      <span className="font-bold">{value}</span>
    </li>
  );
}

function RegisterForm({ address, from }) {
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const { toast } = useUi();
  const { wrongNetwork, appNetwork, switchToApp } = useNetwork();
  const [sponsor, setSponsor] = useState(getStoredSponsor);
  const [step, setStep] = useState("");
  const [error, setError] = useState("");

  const { data: figures, isLoading, refetch } = useReadContracts({
    contracts: [
      { address: CONTRACTS.register, abi: REGISTER_ABI, functionName: "initialDeposit", chainId },
      { address: CONTRACTS.usdt, abi: erc20Abi, functionName: "balanceOf", args: [address], chainId },
      { address: CONTRACTS.usdt, abi: erc20Abi, functionName: "allowance", args: [address, CONTRACTS.gateway], chainId },
    ],
    allowFailure: false,
    query: { enabled: Boolean(CONTRACTS.register) },
  });
  const [deposit, balance, allowance] = figures ?? [];

  const { data: native } = useBalance({ address, chainId });
  const { data: gasPrice } = useGasPrice({ chainId });
  const gasNeeded = gasPrice === undefined ? undefined : gasPrice * GAS_UNITS;
  const hasGas = native !== undefined && gasNeeded !== undefined && native.value >= gasNeeded;

  const trimmed = sponsor.trim();
  const validFormat = isAddress(trimmed);
  const self = validFormat && trimmed.toLowerCase() === address.toLowerCase();
  const { data: sponsorFacts, isLoading: checkingSponsor } = useReadContracts({
    contracts: [
      { address: CONTRACTS.accounts, abi: ACCOUNTS_ABI, functionName: "isUser", args: [trimmed], chainId },
      { address: CONTRACTS.rewards, abi: REWARDS_ABI, functionName: "isActive", args: [trimmed], chainId },
      { address: CONTRACTS.accounts, abi: ACCOUNTS_ABI, functionName: "root", chainId },
      { address: CONTRACTS.rewards, abi: REWARDS_ABI, functionName: "isAgent", args: [trimmed], chainId },
    ],
    allowFailure: false,
    query: { enabled: validFormat && !self },
  });
  const [sponsorIsMember, sponsorHasCapping, root, sponsorIsAgent] = sponsorFacts ?? [];
  // The root wallet starts the tree, so it can sponsor before anyone has capping. Agents may sponsor without capping.
  const sponsorIsRoot = root !== undefined && trimmed.toLowerCase() === root.toLowerCase();
  const sponsorValid = sponsorIsMember === true && (sponsorIsRoot || sponsorHasCapping === true || sponsorIsAgent === true);

  const problem = useMemo(() => {
    if (!trimmed) return "";
    if (!validFormat) return "Enter a valid wallet address.";
    if (self) return "You can't sponsor yourself.";
    if (sponsorIsMember === false) return "This wallet isn't a registered member.";
    if (sponsorIsMember === true && !sponsorValid) return "This sponsor isn't valid. They have no capping left and aren't an agent.";
    return "";
  }, [trimmed, validFormat, self, sponsorIsMember, sponsorValid]);

  useEffect(() => { setError(""); }, [sponsor]);

  // initialDeposit 0 = no deposit: no USDT needed, no approval, register() skips the transfer.
  const noDeposit = deposit === 0n;
  const short = !noDeposit && deposit !== undefined && balance !== undefined && balance < deposit;
  const ready = validFormat && !self && sponsorValid && deposit !== undefined && !short && hasGas;

  const submit = async (e) => {
    e.preventDefault();
    if (!ready || step) return;
    setError("");
    try {
      if (!noDeposit) {
        setStep("Approve USDT in your wallet…");
        if (await ensureAllowance(CONTRACTS.usdt, CONTRACTS.gateway, deposit, address)) await refetch();
      }
      setStep("Confirm your registration…");
      await send({ address: CONTRACTS.register, abi: REGISTER_ABI, functionName: "register", args: [trimmed] }, address);
      clearStoredSponsor();
      await queryClient.invalidateQueries();
      toast("Welcome to ZYQORIX.");
      navigate(from || "/", { replace: true });
    } catch (err) {
      setError(reason(err));
      setStep("");
    }
  };

  if (!CONTRACTS.register) {
    return <section className="section"><div className="card card-body text-center"><p className="text-[13px] text-muted">Registration isn't open on this network yet.</p></div></section>;
  }

  return (
    <section className="section">
      <div className="section-head"><div>
        <h2 className="section-title">Create your membership</h2>
        <p className="section-sub">You need a sponsor who is already a member.</p>
      </div></div>
      <form className="card card-body" onSubmit={submit}>
        <label className="label" htmlFor="sponsor">Sponsor wallet address</label>
        <input id="sponsor" className="input input-filled" type="text" autoComplete="off" spellCheck={false} placeholder="0x…" value={sponsor} onChange={(e) => setSponsor(e.target.value)} disabled={Boolean(step)} />
        {problem && <p className="mt-2 text-[12.5px] font-semibold text-rose-500">{problem}</p>}

        <ul className="mt-5 space-y-2.5">
          <CheckRow ok={hasGas} label={`${GAS_SYMBOL} for the network fee`} value={native === undefined ? "…" : `${Number(formatUnits(native.value, 18)).toFixed(4)} ${GAS_SYMBOL}`} />
          {noDeposit
            ? <CheckRow ok label="Initial deposit" value="Not required" />
            : <CheckRow ok={deposit !== undefined && !short} label={`${isLoading ? "…" : usdt(deposit)} USDT initial deposit`} value={isLoading ? "…" : `${usdt(balance)} USDT`} />}
          <CheckRow ok={sponsorValid && !self} label="Valid sponsor" value={!validFormat ? "—" : checkingSponsor ? "…" : sponsorValid && !self ? "Yes" : "No"} />
        </ul>
        {!noDeposit && <p className="mt-3 text-[12.5px] text-muted">The initial deposit goes to your ZYQORIX wallet balance.</p>}
        {native !== undefined && gasNeeded !== undefined && !hasGas && <p className="mt-2 text-[12.5px] font-semibold text-rose-500">You don't have enough {GAS_SYMBOL} for the network fee.</p>}
        {short && <p className="mt-2 text-[12.5px] font-semibold text-rose-500">You don't have enough USDT for the initial deposit.</p>}
        {error && <p className="mt-3 text-[12.5px] font-semibold text-rose-500" role="alert">{error}</p>}

        {wrongNetwork
          ? <button type="button" className="btn btn-primary btn-block mt-4" onClick={switchToApp}>Switch to {appNetwork}</button>
          : <button type="submit" className="btn btn-primary btn-block mt-4" disabled={!ready || Boolean(step) || checkingSponsor}>{step || "Register"}</button>}
      </form>
    </section>
  );
}

/** Sign-up: a valid sponsor plus the on-chain initial deposit. Every private page leads here until it's done. */
export default function Register() {
  const { address, isConnected, isConnecting, isReconnecting } = useAccount();
  const { isMember, isLoading } = useMember();
  const { state } = useLocation();
  if (isConnecting || isReconnecting || isLoading) return <Checking />;
  if (!isConnected) return <ConnectPrompt text="Connect the wallet you want to register." />;
  if (isMember) return <Navigate to="/" replace />;
  return <RegisterForm address={address} from={state?.from} />;
}
