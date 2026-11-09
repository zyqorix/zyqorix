// Configuration checklist on /admin: every wiring call a contract needs before it can work, read back from chain.
// Rows run in the order of projects/zyqorix/DEPLOY-MAINNET.md. Each item reads one view and passes when
// `ok(value)` is true; a read that reverts counts as not set.
//  - read: [slug, functionName, args?]   slug from ADMIN_CONTRACTS, or an extra target in Admin.jsx
//                                        ("usdt", "pool", "retiredAccounts", "retiredGateway", "retiredLiquidity", "retiredVesting")
//  - fix:  the call that sets it (shown under a cross)
//  - launch: one-way steps done last, before real deposits (crossed on testnet by design)
//  - manual: no chain read; the fix text is the check to do by hand (not counted)
//  - skip: leave the row out on this network
import { parseEther } from "viem";
import { ACTIVE_CHAIN_ID } from "../lib/appkit.js";
import { CONTRACTS } from "./contracts.js";

const ZERO = "0x0000000000000000000000000000000000000000";
const RETIRED = CONTRACTS.retired ?? {};
// The 2026-11-03 audit setting: enough pool history for the 30-minute TWAP on BSC block times.
const TWAP_SLOTS = 4100;
const same = (want) => (v) => typeof v === "string" && Boolean(want) && v.toLowerCase() === want.toLowerCase();
const isSet = (v) => typeof v === "string" && v !== ZERO;
const positive = (v) => typeof v === "bigint" && v > 0n;
const isTrue = (v) => v === true;
const isFalse = (v) => v === false;

export const CHECKLIST = {
  accounts: [
    { label: "Retired accounts paused", read: ["retiredAccounts", "paused"], ok: isTrue, fix: `accounts(${RETIRED.accounts}).setPaused(true)`, skip: !RETIRED.accounts },
    { label: "Rewards is an admin", read: ["accounts", "isAdmin", [CONTRACTS.rewards]], ok: isTrue, fix: "accounts.addAdmin(rewards)" },
    { label: "Register is an admin", read: ["accounts", "isAdmin", [CONTRACTS.register]], ok: isTrue, fix: "accounts.addAdmin(register)" },
    { label: "Owner is a multisig", manual: true, launch: true, fix: "accounts.transferOwnership(multisig), then acceptOwnership from the multisig" },
  ],
  gateway: [
    { label: "Retired gateway paused", read: ["retiredGateway", "paused"], ok: isTrue, fix: `gateway(${RETIRED.gateway}).setPaused(true)`, skip: !RETIRED.gateway },
    { label: "Funder set", read: ["gateway", "funder"], ok: same(CONTRACTS.funder), fix: "contracts.js is stale: set funder to gateway.funder()" },
    { label: "Rewards set", read: ["gateway", "rewards"], ok: same(CONTRACTS.rewards), fix: "gateway.setRewards(rewards)" },
    { label: "Liquidity set", read: ["gateway", "liquidity"], ok: same(CONTRACTS.liquidity), fix: "gateway.setLiquidity(liquidity)" },
    // 300 bps (3%) is the deploy setting; above 5% the fee swap and liquidity adds are easy to sandwich.
    { label: "Liquidity slippage 1–5%", read: ["gateway", "liquiditySlippageBps"], ok: (v) => typeof v === "bigint" && v >= 100n && v <= 500n, fix: "gateway.setLiquiditySlippage(300)" },
    { label: "Gateway not paused", read: ["gateway", "paused"], ok: isFalse, fix: "gateway.setPaused(false)" },
    { label: "Funder locked", read: ["gateway", "funderLocked"], ok: isTrue, fix: "gateway.lockFunder(), after lockLiquidity", launch: true },
  ],
  funder: [
    { label: "Gateway set", read: ["funder", "gateway"], ok: same(CONTRACTS.gateway), fix: "funder.setGateway(gateway)" },
    { label: "Trading wallet is the exchanger", read: ["funder", "tradingWallet"], ok: same(CONTRACTS.exchanger), fix: "funder.setTradingWallet(exchanger)" },
    { label: "Rewards set", read: ["funder", "rewards"], ok: same(CONTRACTS.rewards), fix: "funder.setRewards(rewards), after gateway.setRewards" },
    { label: "At least one funding wallet", read: ["funder", "walletCount"], ok: positive, fix: "funder.addFundingWallet(wallet)" },
    { label: "No funding wallet is an exchanger", manual: true, fix: "check funder.fundingWallets() against the exchanger list, the exchanger contract and liquidity.tradingWallet (M-1)" },
    { label: "Funding wallets approved the funder", manual: true, fix: "each funding wallet approves the funder on /fund" },
  ],
  exchanger: [
    { label: "Settles in USDT", read: ["exchanger", "usdt"], ok: same(CONTRACTS.usdt), fix: "set at deploy, redeploy exchanger" },
    { label: "Has exchangers", read: ["exchanger", "exchangerCount"], ok: positive, fix: "exchanger.addExchanger(wallet)" },
  ],
  rewards: [
    { label: "Points at this gateway", read: ["rewards", "gateway"], ok: same(CONTRACTS.gateway), fix: "set at deploy, redeploy rewards" },
    { label: "Vesting set", read: ["rewards", "vesting"], ok: same(CONTRACTS.vesting), fix: "rewards.setVesting(vesting)" },
    { label: "Reward pool funded", read: ["funder", "rewardPool"], ok: positive, fix: "funder.fundRewards(amount), see Health" },
  ],
  register: [
    { label: "Register is an accounts admin", read: ["accounts", "isAdmin", [CONTRACTS.register]], ok: isTrue, fix: "accounts.addAdmin(register)" },
    { label: "Points at this gateway", read: ["register", "gateway"], ok: same(CONTRACTS.gateway), fix: "set at deploy, redeploy register" },
    // 0 on the NAS by design (free test registrations); on mainnet it is the anti-spam first deposit.
    { label: "Anti-spam initial deposit set", read: ["register", "initialDeposit"], ok: positive, fix: "register.setInitialDeposit(50e18)", skip: ACTIVE_CHAIN_ID === 31337 },
  ],
  vesting: [
    { label: "Retired vesting migrated here", read: ["retiredVesting", "migratedTo"], ok: same(CONTRACTS.vesting), fix: `vesting(${RETIRED.vesting}).emergencyWithdraw(vesting)`, skip: !RETIRED.vesting },
    { label: "Funded with ZQR", read: ["vesting", "available"], ok: positive, fix: "transfer ZQR to vesting" },
  ],
  liquidity: [
    { label: "Retired position withdrawn", read: ["retiredLiquidity", "TOKENID"], ok: (v) => v === 0n, fix: `liquidity(${RETIRED.liquidity}).emergencyWithdraw(), then tokenWithdraw()`, skip: !RETIRED.liquidity },
    { label: "Pool initialized", read: ["liquidity", "FEE"], ok: (v) => Number(v) > 0, fix: "liquidity.initializePool(pool)" },
    { label: "Router approved", read: ["usdt", "allowance", [CONTRACTS.liquidity, CONTRACTS.swapRouter]], ok: positive, fix: "liquidity.initializeApproval()", skip: !CONTRACTS.swapRouter },
    // slot0[4] is observationCardinalityNext: the slots requested. The pool fills them as trades land.
    { label: `TWAP slots ≥ ${TWAP_SLOTS.toLocaleString()} requested`, read: ["pool", "slot0"], ok: (v) => Array.isArray(v) && Number(v[4]) >= TWAP_SLOTS, fix: "liquidity.growObservationCardinality(next): 1200, 2200, 3200, then 4100 (next is the new total)", skip: !CONTRACTS.pool },
    { label: "TWAP price ready", read: ["liquidity", "convertToken", [CONTRACTS.usdt, parseEther("1")]], ok: positive, fix: "seed the pool, then wait 30 minutes" },
    { label: "Position minted", read: ["liquidity", "TOKENID"], ok: positive, fix: "depositUSDT, depositToken, initializePosition()" },
    { label: "Trading wallet is the exchanger", read: ["liquidity", "tradingWallet"], ok: same(CONTRACTS.exchanger), fix: "liquidity.setTradingWallet(exchanger)" },
    { label: "Liquidity locked", read: ["liquidity", "liquidityLocked"], ok: isTrue, fix: "liquidity.lockLiquidity()", launch: true },
  ],
  zqr: [
    { label: "Ownership renounced", read: ["zqr", "owner"], ok: (v) => v === ZERO, fix: "renounced in the constructor" },
  ],
};
