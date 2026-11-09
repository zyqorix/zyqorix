import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { ChevronRight, Copy, Link2, Search, UserRound, UserRoundCheck, UsersRound } from "lucide-react";
import { getAddress, isAddress, zeroAddress } from "viem";
import { useAccount, useReadContract } from "wagmi";
import { readContract, readContracts } from "wagmi/actions";
import { useUi } from "../components/Ui.jsx";
import { ACCOUNTS_ABI, CONTRACTS, REWARDS_ABI } from "../config/contracts.js";
import { ACTIVE_CHAIN_ID, wagmiConfig } from "../lib/appkit.js";

const accounts = { address: CONTRACTS.accounts, abi: ACCOUNTS_ABI, chainId: ACTIVE_CHAIN_ID };
const rewards = { address: CONTRACTS.rewards, abi: REWARDS_ABI, chainId: ACTIVE_CHAIN_ID };
const MAX_GENERATION = 10; // generations shown below the top node
const PAGE = 25; // directs loaded per request
const MAX_WALK = 1_000; // sponsor hops checked before giving up

const short = (wallet) => `${wallet.slice(0, 6)}…${wallet.slice(-4)}`;
const same = (a, b) => a.toLowerCase() === b.toLowerCase();

/** True when `target` is `me` or somewhere below `me`: walk up the sponsors from `target` until we meet `me`. */
async function isInNetwork(target, me) {
  if (!(await readContract(wagmiConfig, { ...accounts, functionName: "isUser", args: [target] }))) return false;
  let cursor = target;
  for (let hop = 0; hop < MAX_WALK; hop++) {
    if (same(cursor, me)) return true;
    const [sponsor] = await readContract(wagmiConfig, { ...accounts, functionName: "getAffiliate", args: [cursor] });
    if (sponsor === zeroAddress) return false;
    cursor = sponsor;
  }
  return false;
}

/** One page of a member's directs, with each direct's own direct count and active status. */
async function loadDirects(parent, offset) {
  const [list, total] = await readContract(wagmiConfig, { ...accounts, functionName: "getChildren", args: [parent, BigInt(offset), BigInt(PAGE)] });
  const details = await readContracts(wagmiConfig, {
    contracts: list.flatMap((wallet) => [
      { ...accounts, functionName: "getAffiliate", args: [wallet] },
      { ...rewards, functionName: "isActive", args: [wallet] },
    ]),
  });
  const members = list.map((wallet, i) => ({
    wallet,
    directs: Number(details[i * 2].result?.[1] ?? 0n),
    active: details[i * 2 + 1].result === true,
  }));
  return { members, total: Number(total) };
}

function CopyButton({ wallet }) {
  const { toast } = useUi();
  const copy = async (event) => {
    event.stopPropagation();
    try {
      await navigator.clipboard.writeText(wallet);
      toast("Wallet address copied.");
    } catch {
      toast("Couldn't copy. Select the address instead.");
    }
  };
  return (
    <button type="button" className="btn btn-ghost btn-xs btn-square" aria-label={`Copy ${wallet}`} onClick={copy}>
      <Copy className="size-4" />
    </button>
  );
}

/** The directs of `parent`, loaded page by page when it is expanded. */
function Directs({ parent, generation, onOpenTop }) {
  const [pages, setPages] = useState(1);
  const queries = Array.from({ length: pages }, (_, i) => i * PAGE);
  return queries.map((offset, i) => (
    <DirectsPage key={offset} parent={parent} offset={offset} generation={generation} onOpenTop={onOpenTop}
      last={i === pages - 1} onMore={() => setPages((n) => n + 1)} />
  ));
}

function DirectsPage({ parent, offset, generation, onOpenTop, last, onMore }) {
  const { data, isLoading, isError } = useQuery({
    queryKey: ["directs", ACTIVE_CHAIN_ID, parent, offset],
    queryFn: () => loadDirects(parent, offset),
    staleTime: 60_000,
  });
  if (isLoading) return <p className="py-2 pl-2 text-[12.5px] text-muted">Loading…</p>;
  if (isError) return <p className="py-2 pl-2 text-[12.5px] text-rose-500">Couldn't load this level. Close and open it again.</p>;
  return (
    <>
      {data.members.map((member) => (
        <TreeNode key={member.wallet} member={member} generation={generation} onOpenTop={onOpenTop} />
      ))}
      {last && offset + PAGE < data.total && (
        <button type="button" className="btn btn-ghost btn-sm my-1" onClick={onMore}>
          Show more ({data.total - offset - PAGE} left)
        </button>
      )}
    </>
  );
}

/** A member row. Expanding it loads its directs. Generation 10 is the deepest that opens. */
function TreeNode({ member, generation, onOpenTop }) {
  const [open, setOpen] = useState(false);
  const canOpen = member.directs > 0 && generation < MAX_GENERATION;
  return (
    <div>
      <div className="flex items-center gap-1.5 rounded-xl py-1.5 pr-1 hover:bg-brand/5">
        <button type="button" className="flex min-w-0 flex-1 items-center gap-2 text-left disabled:cursor-default" disabled={!canOpen}
          aria-expanded={canOpen ? open : undefined} onClick={() => setOpen((v) => !v)}>
          <ChevronRight className={`size-4 shrink-0 text-muted transition-transform ${open ? "rotate-90" : ""} ${canOpen ? "" : "opacity-0"}`} />
          <span className="min-w-0">
            <span className="block truncate font-mono text-[13px] font-semibold">{short(member.wallet)}</span>
            <span className="block text-[11.5px] text-muted">
              Gen {generation} · {member.directs} direct{member.directs === 1 ? "" : "s"}
              {member.directs > 0 && generation >= MAX_GENERATION && " · open as top to see more"}
            </span>
          </span>
        </button>
        {member.active && <span className="chip chip-soft">Active</span>}
        <CopyButton wallet={member.wallet} />
        {member.directs > 0 && (
          <button type="button" className="btn btn-ghost btn-xs" onClick={() => onOpenTop(member.wallet)}>Open</button>
        )}
      </div>
      {open && (
        <div className="ml-[9px] border-l border-line pl-3">
          <Directs parent={member.wallet} generation={generation + 1} onOpenTop={onOpenTop} />
        </div>
      )}
    </div>
  );
}

function Summary({ address }) {
  const { toast } = useUi();
  const { data } = useReadContract({ ...accounts, functionName: "getAffiliate", args: [address], query: { enabled: Boolean(address) } });
  const link = address ? `${window.location.origin}/#/${address}` : "";
  const copyLink = async () => {
    try {
      await navigator.clipboard.writeText(link);
      toast("Referral link copied.");
    } catch {
      toast("Couldn't copy. Select the link instead.");
    }
  };
  const sponsor = data?.[0];
  return (
    <section className="section">
      <div className="card">
        <div className="list">
          <div className="list-item"><span className="icon-box icon-box-sm"><UserRoundCheck className="size-5" /></span><span className="list-body"><span className="list-title block">Sponsor</span></span><span className="font-mono font-bold">{sponsor ? (sponsor === zeroAddress ? "None" : short(sponsor)) : "—"}</span></div>
          <div className="list-item"><span className="icon-box icon-box-sm bg-sky-500/12 text-sky-500"><UsersRound className="size-5" /></span><span className="list-body"><span className="list-title block">Direct referrals</span></span><span className="font-bold">{data ? Number(data[1]) : "—"}</span></div>
          <button type="button" className="list-item w-full text-left" onClick={copyLink} disabled={!link}>
            <span className="icon-box icon-box-sm bg-amber-500/12 text-amber-500"><Link2 className="size-5" /></span>
            <span className="list-body min-w-0"><span className="list-title block">Referral link</span><span className="list-sub block truncate">{link || "—"}</span></span>
            <Copy className="size-4 text-muted" />
          </button>
        </div>
      </div>
    </section>
  );
}

/** Your genealogy as an expandable tree, 10 generations deep from the top node. Any wallet in your network can be the top node. */
export default function Network() {
  const { address } = useAccount();
  const [top, setTop] = useState("");
  const [search, setSearch] = useState("");
  const [checking, setChecking] = useState(false);
  const [error, setError] = useState("");
  const current = top || address;

  const { data: topInfo } = useReadContract({ ...accounts, functionName: "getAffiliate", args: [current], query: { enabled: Boolean(current) } });
  const { data: topActive } = useReadContract({ ...rewards, functionName: "isActive", args: [current], query: { enabled: Boolean(current) } });

  const openTop = async (wallet) => {
    setError("");
    if (!isAddress(wallet)) {
      setError("Enter a full wallet address (0x…).");
      return;
    }
    const target = getAddress(wallet);
    setChecking(true);
    try {
      if (await isInNetwork(target, address)) {
        setTop(same(target, address) ? "" : target);
        setSearch("");
      } else {
        setError("That wallet isn't in your network. You can only open wallets below you.");
      }
    } catch {
      setError("We couldn't check that wallet. Try again.");
    }
    setChecking(false);
  };

  if (!address) return null;
  const topMember = { wallet: current, directs: topInfo ? Number(topInfo[1]) : 0, active: topActive === true };

  return (
    <>
      <Summary address={address} />

      <section className="section">
        <div className="section-head"><div>
          <h2 className="section-title">Genealogy</h2>
          <p className="section-sub">Expand a wallet to load its directs. Up to {MAX_GENERATION} generations below the top wallet.</p>
        </div></div>

        <form className="mb-3 flex gap-2" onSubmit={(e) => { e.preventDefault(); openTop(search.trim()); }}>
          <input className="input input-filled min-w-0 flex-1 font-mono text-[13px]" type="text" autoComplete="off" spellCheck={false} placeholder="Open a wallet in your network (0x…)"
            aria-label="Wallet address to open" value={search} onChange={(e) => setSearch(e.target.value)} disabled={checking} />
          <button type="submit" className="btn btn-primary btn-sm" disabled={checking || !search.trim()}>
            {checking ? "Checking…" : <><Search className="size-4" />Open</>}
          </button>
        </form>
        {error && <p className="mb-3 text-[12.5px] font-semibold text-rose-500" role="alert">{error}</p>}

        <div className="card card-body">
          <div className="mb-2 flex items-center gap-2 border-b border-line pb-2">
            <UserRound className="size-5 text-brand" />
            <div className="min-w-0 flex-1">
              <p className="truncate font-mono text-[13px] font-bold">{short(current)}{!top && <span className="ml-1.5 font-sans text-[11.5px] font-semibold text-muted">(you)</span>}</p>
              <p className="text-[11.5px] text-muted">Top wallet · {topMember.directs} direct{topMember.directs === 1 ? "" : "s"}</p>
            </div>
            {topMember.active && <span className="chip chip-soft">Active</span>}
            <CopyButton wallet={current} />
            {top && <button type="button" className="btn btn-soft btn-xs" onClick={() => { setTop(""); setError(""); }}>Back to me</button>}
          </div>
          {topMember.directs > 0
            ? <Directs key={current} parent={current} generation={1} onOpenTop={openTop} />
            : <div className="py-4 text-center"><UsersRound className="mx-auto size-8 text-muted" /><p className="mt-2 text-[13px] text-muted">No referrals yet.</p></div>}
        </div>
      </section>
    </>
  );
}
