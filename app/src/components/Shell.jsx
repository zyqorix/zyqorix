import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Link, NavLink, Outlet, useLocation, useNavigate } from "react-router-dom";
import {
  ArrowDownToLine, ArrowUpFromLine, ChevronRight, Gift, House, Magnet, Menu, Moon, Network, ShieldCheck, Sparkles, Sun, WalletMinimal, X,
} from "lucide-react";
import { useAccount } from "wagmi";
import { appKit } from "../lib/appkit.js";
import { ACCENTS, useTheme } from "../lib/theme.js";
import { useIsAdmin } from "../hooks/useIsAdmin.js";
import { useMember } from "../hooks/useMember.js";
import { useNetwork } from "../hooks/useNetwork.js";
import { AccentPicker } from "./AccentPicker.jsx";
import { same, useFundingWallets } from "./FundingWallets.jsx";
import { Sheet, UiContext, useUi } from "./Ui.jsx";
import { DepositSheet, WithdrawSheet } from "./MoneySheets.jsx";

const NAV = [
  { to: "/", icon: House, label: "Home" },
  { to: "/wallet", icon: WalletMinimal, label: "Wallet" },
  { fab: true },
  { to: "/network", icon: Network, label: "Network" },
  { to: "/rewards", icon: Gift, label: "Rewards" },
];
const TITLES = { "/": "ZYQORIX", "/wallet": "Wallet", "/network": "Network", "/account": "Account", "/rewards": "Rewards", "/rewards/leadershippool": "Leadership Pool", "/admin": "Admin", "/register": "Register", "/fund": "Funding", "/about": "About", "/about/rewardsplan": "Rewards Plan", "/about/faq": "FAQ" };

function Header({ title, clear, onMenu, theme }) {
  const [scrolled, setScrolled] = useState(false);
  useEffect(() => {
    const onScroll = () => setScrolled(window.scrollY > 40);
    onScroll();
    window.addEventListener("scroll", onScroll, { passive: true });
    return () => window.removeEventListener("scroll", onScroll);
  }, []);
  return (
    <>
      <header className={`header ${clear ? `header-clear${scrolled ? " is-scrolled" : ""}` : "header-solid"}`}>
        <button type="button" className="head-btn" onClick={onMenu} aria-label="Open menu"><Menu className="size-5" /></button>
        <span className="header-title">{title}</span>
        <button type="button" className="head-btn" onClick={theme.toggle} aria-label="Toggle dark mode">
          <Moon className="size-5 dark:hidden" /><Sun className="hidden size-5 dark:block" />
        </button>
      </header>
      {!clear && <div className="header-spacer" />}
    </>
  );
}

function TabBar({ onFab }) {
  return (
    <nav className="tabbar" aria-label="Main">
      <div className="tabbar-inner">
        {NAV.map((t) => t.fab ? (
          <button key="fab" type="button" className="tab" onClick={onFab} aria-label="Quick actions">
            <span className="tab-fab"><Sparkles className="size-6" /></span>
          </button>
        ) : (
          <NavLink key={t.to} to={t.to} end className={({ isActive }) => `tab${isActive ? " is-active" : ""}`}>
            <t.icon /><span>{t.label}</span>
          </NavLink>
        ))}
      </div>
    </nav>
  );
}

function Drawer({ open, onClose, theme }) {
  const { isAdmin } = useIsAdmin();
  const { address } = useAccount();
  const { wallets } = useFundingWallets();
  const { name, wrongNetwork, appNetwork, switchToApp } = useNetwork();
  const funding = isAdmin || wallets.some((w) => same(w, address));
  const links = [
    ...NAV,
    ...(funding ? [{ to: "/fund", icon: Magnet, label: "Funding wallets" }] : []),
    ...(isAdmin ? [{ to: "/admin", icon: ShieldCheck, label: "Admin" }] : []),
  ];
  return (
    <>
      <aside className={`drawer${open ? " is-open" : ""}`} aria-label="Side menu" aria-hidden={!open} inert={!open}>
        <div className="bg-mesh shape-bubbles px-5 pb-6 pt-[calc(env(safe-area-inset-top)+20px)] text-white">
          <div className="flex items-center justify-between">
            <span className="grid size-12 place-items-center rounded-2xl bg-white/20 text-xl font-black backdrop-blur">Z</span>
            <button type="button" className="grid size-10 place-items-center rounded-2xl bg-white/15 backdrop-blur" onClick={onClose} aria-label="Close menu"><X className="size-5" /></button>
          </div>
          <p className="mt-4 text-lg font-extrabold">ZYQORIX</p>
          <p className="text-[13px] text-white/75">{name}</p>
          {wrongNetwork && <button type="button" className="btn btn-white btn-sm mt-3" onClick={switchToApp}>Switch to {appNetwork}</button>}
        </div>
        <nav className="flex-1 overflow-y-auto p-3">
          {links.filter((t) => !t.fab).map((t) => (
            <NavLink key={t.to} to={t.to} end onClick={onClose} className={({ isActive }) => `menu-link${isActive ? " is-active" : ""}`}>
              <span className="icon-box icon-box-sm"><t.icon className="size-5" /></span>{t.label}<ChevronRight className="size-5" />
            </NavLink>
          ))}
          <div className="divider my-3" />
          <p className="eyebrow mb-3 mt-4 px-3">Highlight color</p>
          <div className="px-3"><AccentPicker theme={theme} size="size-8" /></div>
        </nav>
      </aside>
      <div className={`drawer-backdrop${open ? " is-open" : ""}`} onClick={onClose} />
    </>
  );
}

function QuickSheet() {
  const { openSheet } = useUi();
  return (
    <Sheet id="quick" label="Quick actions">
      <div className="px-5 pb-2 pt-3"><h3 className="text-lg font-extrabold">Quick actions</h3></div>
      <div className="grid grid-cols-2 gap-3 px-4 pb-3">
        <button type="button" className="btn btn-primary btn-block" onClick={() => openSheet("deposit")}><ArrowDownToLine className="size-5" />Deposit</button>
        <button type="button" className="btn btn-soft btn-block" onClick={() => openSheet("withdraw")}><ArrowUpFromLine className="size-5" />Withdraw</button>
      </div>
      <div className="px-4"><Link to="/rewards" className="btn btn-neutral btn-block" onClick={() => openSheet(null)}>Rewards</Link></div>
    </Sheet>
  );
}

/** The Lumen app shell: header, tab bar, drawer, sheets and toasts. */
export function Shell() {
  const { pathname } = useLocation();
  const theme = useTheme();
  const { isConnected } = useAccount();
  const { isMember } = useMember();
  const navigate = useNavigate();
  const [drawerOpen, setDrawerOpen] = useState(false);
  const [sheet, openSheet] = useState(null);
  const [toasts, setToasts] = useState([]);
  const nextId = useRef(0);

  const toast = useCallback((message) => {
    const id = ++nextId.current;
    setToasts((t) => [...t, { id, message }]);
    setTimeout(() => setToasts((t) => t.filter((x) => x.id !== id)), 2800);
  }, []);

  useEffect(() => {
    document.body.style.overflow = sheet || drawerOpen ? "hidden" : "";
  }, [sheet, drawerOpen]);

  useEffect(() => {
    const onKey = (e) => { if (e.key === "Escape") { openSheet(null); setDrawerOpen(false); } };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, []);

  useEffect(() => { window.scrollTo(0, 0); }, [pathname]);

  // Keep Reown's modal on the app's light or dark theme and accent.
  useEffect(() => {
    const root = document.documentElement;
    const sync = () => appKit.setThemeMode(root.classList.contains("dark") ? "dark" : "light");
    sync();
    const observer = new MutationObserver(sync);
    observer.observe(root, { attributes: true, attributeFilter: ["class"] });
    return () => observer.disconnect();
  }, []);

  useEffect(() => {
    appKit.setThemeVariables({ "--w3m-accent": ACCENTS[theme.accent] });
  }, [theme.accent]);

  const ui = useMemo(() => ({ sheet, openSheet, toast, theme }), [sheet, toast, theme]);

  return (
    <UiContext.Provider value={ui}>
      <div className="app">
        <Header title={TITLES[pathname] || "ZYQORIX"} clear={pathname === "/"} onMenu={() => setDrawerOpen(true)} theme={theme} />
        <main className="page" id="main"><Outlet /></main>
        <TabBar onFab={() => {
          if (!isConnected) appKit.open();
          else if (isMember) openSheet("quick");
          else navigate("/register");
        }} />
      </div>
      <Drawer open={drawerOpen} onClose={() => setDrawerOpen(false)} theme={theme} />
      <div className={`backdrop${sheet ? " is-open" : ""}`} onClick={() => openSheet(null)} />
      <QuickSheet />
      <DepositSheet />
      <WithdrawSheet />
      <div className="toast-root" aria-live="polite">
        {toasts.map((t) => <div key={t.id} className="toast" role="status"><span className="flex-1">{t.message}</span></div>)}
      </div>
    </UiContext.Provider>
  );
}
