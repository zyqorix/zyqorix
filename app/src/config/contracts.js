import { ACTIVE_CHAIN_ID } from "../lib/appkit.js";

// USDT and ZQR are their BSC addresses on both: the shared anvil has a mock etched at each
// (chain/script/deploy-usdt.js, chain/script/deploy-zqr.js), and vesting/liquidity hardcode ZQR.
const USDT = "0x55d398326f99059fF775485246999027B3197955";
const ZQR = "0x43ADE7aE5E14e6dadD0f6967a0aDEADe56095e70";

// Anvil values come from chain/deployments/zyqorix.31337.json.
const ADDRESSES = {
  31337: { usdt: USDT, accounts: "0xD9cA22646bDbB0772ff1B15CC139e229f0AA7b64", gateway: "0x2F1448a525117262408e4b6c24C3161037067D5d", register: "0x8525A10eeBF11E689F4a456A2AE172eaC9DaD6C9", rewards: "0x319554eF50998660776CF0EF924073e5c416b890", funder: "0x3FAf6E834f0fc618020A25c45780a1a2efAEf0B4", exchanger: "0xa4761E911dDC47f290928c0d3F7a908132289Ce7", vesting: "0x7Df0dB859FA3C423ac28ea09Eb2eeb941F3E9541", liquidity: "0x0Ee29547347E41fD7Bf14a0d064421275C2ae0bA", zqr: ZQR, swapRouter: "0x4Af81C96d19315212358f9E4a774bBcC0390B5f0", pool: "",
    // The eighth stack. Its liquidity 0x1CD1 is left out: the stand-in DEX can't close a position (runbook step 0.3).
    retired: {
      accounts: "0x1Da55d8D54B0a4fbb8bC75C179fb28def5E91330", exchanger: "0x72cdd30c3989D7f87bA563b0DA6ECcdd79fcdA9F", vesting: "0xE6711c866D4ee72663521CB2ff8B72879b5f40D0",
      funder: "0xB2a1012200e3B0c228DDbD18c7312C6137dd3662", gateway: "0x9e5759a3b59E5EFeB980f3884db390418B16b6FE", rewards: "0x116cEb7B0aF67cE7Eb006697f2a6864CBb7858C3", register: "0xc325d32CCc1ADf49d602a013B702Eeb9Fa02bF1d",
    } },
  // swapRouter: the router liquidity.sol was deployed with (its getter is private). Only the admin checklist reads it.
  // pool: the PancakeSwap V3 ZQR/USDT pool liquidity.sol trades on (the checklist reads its TWAP slots; "" = skip).
  // retired: the previous stack. The checklist confirms it is disarmed (paused, position withdrawn, vesting migrated), and
  // the deploy list on /admin shows a contract as still to deploy while its address here equals the retired one.
  // exchanger: exchangerdisbursement.sol, the funder's trading wallet.
  56: { usdt: USDT, accounts: "0xAB26C1ffcF3Ef20d53a12dd3B99850B376e68c45", gateway: "0x335Ffb932dd7729CfeCEF803ED5C0C44CB5b0d60", register: "0xE2c8C041186b9Ad13C9F3320DbC71c0d46642687", rewards: "0x2fc14F2b81B295811FAbd0c89ccC076f4d2271a9", funder: "0xe572591A48f39324895864380aae6E3dB953aD9C", exchanger: "0x0C2fe227bB435ACD6189C10F5a951BbdbC559F55", vesting: "0x60818CdD14951E2e3e91054AD9696b31A2d3018c", liquidity: "0xb0EB2Dd04f943B4466EA95A19671E8da579651E5", zqr: ZQR, swapRouter: "0x1b81D678ffb9C0263b24A97847620C99d213eB14", pool: "0xDac4D29e16b87e3D48c80CC569e8040C454582BF",
    retired: {
      accounts: "0xAB26C1ffcF3Ef20d53a12dd3B99850B376e68c45", exchanger: "0x0C2fe227bB435ACD6189C10F5a951BbdbC559F55", liquidity: "0xb0EB2Dd04f943B4466EA95A19671E8da579651E5", vesting: "0x60818CdD14951E2e3e91054AD9696b31A2d3018c",
      funder: "0xe572591A48f39324895864380aae6E3dB953aD9C", gateway: "0x335Ffb932dd7729CfeCEF803ED5C0C44CB5b0d60", rewards: "0x2fc14F2b81B295811FAbd0c89ccC076f4d2271a9", register: "0xE2c8C041186b9Ad13C9F3320DbC71c0d46642687",
    } },
};

export const CONTRACTS = ADDRESSES[ACTIVE_CHAIN_ID];

export const ACCOUNTS_ABI = [
  {
    type: "function",
    name: "root",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "address" }],
  },
  {
    type: "function",
    name: "registeredAt",
    stateMutability: "view",
    inputs: [{ name: "user", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "checkIsAdmin",
    stateMutability: "view",
    inputs: [{ name: "addr", type: "address" }],
    outputs: [{ name: "", type: "bool" }],
  },
  {
    type: "function",
    name: "isUser",
    stateMutability: "view",
    inputs: [{ name: "user", type: "address" }],
    outputs: [{ name: "", type: "bool" }],
  },
  {
    type: "function",
    name: "getAffiliate",
    stateMutability: "view",
    inputs: [{ name: "user", type: "address" }],
    outputs: [{ name: "referral", type: "address" }, { name: "directCount", type: "uint256" }],
  },
  {
    type: "function",
    name: "getChildren",
    stateMutability: "view",
    inputs: [{ name: "user", type: "address" }, { name: "offset", type: "uint256" }, { name: "limit", type: "uint256" }],
    outputs: [{ name: "result", type: "address[]" }, { name: "total", type: "uint256" }],
  },
];

const view = (name, inputs, outputs) => ({ type: "function", name, stateMutability: "view", inputs, outputs });
const write = (name, inputs = []) => ({ type: "function", name, stateMutability: "nonpayable", inputs, outputs: [] });
const uint = (name = "") => ({ name, type: "uint256" });
const user = { name: "user", type: "address" };

export const REWARDS_ABI = [
  view("DAY", [], [uint()]),
  view("capBps", [uint("tier")], [uint()]),
  view("unclaimedDaily", [user], [uint()]),
  view("firstActivation", [user], [uint()]),
  view("rewardCredit", [user], [uint()]),
  view("activationPoolNeed", [user, uint("tier")], [uint()]),
  view("agentCredit", [user], [uint()]),
  view("withdrawable", [user], [uint()]),
  view("FORFEIT_AT_ZERO_CAPPING", [], [{ name: "", type: "bool" }]),
  view("isActive", [user], [{ name: "", type: "bool" }]),
  view("isAgent", [user], [{ name: "", type: "bool" }]),
  view("currentMonth", [], [uint()]),
  view("monthLeaders", [uint("month")], [{ name: "", type: "address[]" }]),
  view("monthPool", [uint("month")], [uint()]),
  view("monthVolume", [uint("month"), user], [uint()]),
  view("nextTier", [user], [uint()]),
  view("tierCapping", [user, uint("tier")], [uint()]),
  view("isTierUnlocked", [user, uint("tier")], [{ name: "", type: "bool" }]),
  view("getUser", [user], [{
    name: "v",
    type: "tuple",
    components: [
      uint("walletBalance"), uint("agentBalance"), uint("capping"), uint("activeValue"), uint("activeDirects"),
      uint("totalIncome"), uint("pendingDaily"), uint("pendingLeadership"), uint("generationBalance"),
      uint("monthVolume"), uint("nextClaim"),
      { name: "activeTiers", type: "uint8[]" },
      { name: "isAgent", type: "bool" },
    ],
  }]),
  write("activate", [uint("tier")]),
  write("claimDaily"),
  write("claimGeneration"),
  write("claimLeadership"),
];

export const FUNDER_ABI = [view("rewardPool", [], [uint()]), view("pendingFunding", [], [uint()])];

export const GATEWAY_ABI = [
  view("minDeposit", [], [uint()]),
  view("coolDown", [user], [uint()]),
  view("withdrawalMin", [], [uint()]),
  view("withdrawalMax", [], [uint()]),
  view("withdrawalStep", [], [uint()]),
  view("withdrawal_fee", [], [uint()]),
  write("withdrawAgent", [uint("amount")]),
  write("deposit", [{ name: "tokenAddress", type: "address" }, uint("amount")]),
  write("withdraw", [uint("amount")]),
];

export const REGISTER_ABI = [
  {
    type: "function",
    name: "initialDeposit",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "register",
    stateMutability: "nonpayable",
    inputs: [{ name: "sponsor", type: "address" }],
    outputs: [],
  },
];
