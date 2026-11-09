// The contracts the admin console can open. ABIs are generated from the Foundry build:
//   cd chain && forge inspect src/zyqorix/<file>.sol:<Contract> abi --json > <app>/src/config/abi/<file>.json
import { ArrowLeftRight, Coins, Droplets, Gift, Hourglass, Landmark, Split, UserPlus, Users } from "lucide-react";
import accountsAbi from "./abi/accounts.json";
import exchangerAbi from "./abi/exchangerdisbursement.json";
import funderAbi from "./abi/funder.json";
import gatewayAbi from "./abi/gateway.json";
import liquidityAbi from "./abi/liquidity.json";
import registerAbi from "./abi/register.json";
import rewardsAbi from "./abi/rewards.json";
import vestingAbi from "./abi/vesting.json";
import zqrAbi from "./abi/zqrtoken.json";
import { CONTRACTS } from "./contracts.js";

export const ADMIN_CONTRACTS = [
  { slug: "accounts", label: "Accounts", abi: accountsAbi, address: CONTRACTS.accounts, icon: Users, tone: "bg-sky-500/12 text-sky-500" },
  { slug: "gateway", label: "Gateway", abi: gatewayAbi, address: CONTRACTS.gateway, icon: ArrowLeftRight, tone: "bg-emerald-500/12 text-emerald-500" },
  { slug: "funder", label: "Funder", abi: funderAbi, address: CONTRACTS.funder, icon: Landmark, tone: "bg-amber-500/12 text-amber-500" },
  { slug: "exchanger", label: "Exchanger", abi: exchangerAbi, address: CONTRACTS.exchanger, icon: Split, tone: "bg-lime-500/12 text-lime-500" },
  { slug: "rewards", label: "Rewards", abi: rewardsAbi, address: CONTRACTS.rewards, icon: Gift, tone: "bg-rose-500/12 text-rose-500" },
  { slug: "register", label: "Register", abi: registerAbi, address: CONTRACTS.register, icon: UserPlus, tone: "bg-violet-500/12 text-violet-500" },
  { slug: "vesting", label: "Vesting", abi: vestingAbi, address: CONTRACTS.vesting, icon: Hourglass, tone: "bg-teal-500/12 text-teal-500" },
  { slug: "liquidity", label: "Liquidity", abi: liquidityAbi, address: CONTRACTS.liquidity, icon: Droplets, tone: "bg-cyan-500/12 text-cyan-500" },
  { slug: "zqr", label: "ZQR Token", abi: zqrAbi, address: CONTRACTS.zqr, icon: Coins, tone: "bg-orange-500/12 text-orange-500" },
];

/** Writes that pull tokens with transferFrom, so they need an ERC-20 allowance first (verified against the
 *  .sol sources, 2026-11-02). Each entry says which token, who pays, who spends and how much:
 *  - token: "usdt" | "zqr" | { arg: i }        the token address
 *  - payer: "me" | { arg: i }                   whose tokens move (the allowance owner)
 *  - spender: "contract" | "me"                 who calls transferFrom (the allowance spender)
 *  - amount: { arg: i } | { read: [slug, fn] }  how much is pulled */
export const APPROVALS = {
  "gateway.deposit": { token: { arg: 0 }, payer: "me", spender: "contract", amount: { arg: 1 } },
  // depositFor is the register hub's path: it pulls from `user`, who approves the gateway
  "gateway.depositFor": { token: { arg: 1 }, payer: { arg: 0 }, spender: "contract", amount: { arg: 2 } },
  "funder.fundRewards": { token: "usdt", payer: "me", spender: "contract", amount: { arg: 0 } },
  "liquidity.addLiquidityUSDT": { token: "usdt", payer: "me", spender: "contract", amount: { arg: 0 } },
  "liquidity.swapUSDTToToken": { token: "usdt", payer: "me", spender: "contract", amount: { arg: 0 } },
  "liquidity.depositUSDT": { token: "usdt", payer: "me", spender: "contract", amount: { arg: 0 } },
  "liquidity.depositToken": { token: "zqr", payer: "me", spender: "contract", amount: { arg: 0 } },
  // register pulls through gateway.depositFor, so the member approves the gateway, not register
  "register.register": { token: "usdt", payer: "me", spender: "gateway", amount: { read: ["register", "initialDeposit"] } },
  "zqr.burnFrom": { token: "zqr", payer: { arg: 0 }, spender: "me", amount: { arg: 1 } },
  "zqr.transferFrom": { token: "zqr", payer: { arg: 0 }, spender: "me", amount: { arg: 2 } },
};

/** Writes that can't be undone, or that move control or all funds. The console asks twice before sending. */
export const IRREVERSIBLE = new Set([
  "lockFunder", "lockLiquidity", "emergencyWithdraw", "renounceOwnership", "transferOwnership",
  "removeUser", "withdrawFunds", "tokenWithdraw", "revokeApproval", "initializePool", "initializePosition",
]);
