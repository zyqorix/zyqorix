import { ACTIVE_CHAIN_ID } from "../lib/appkit.js";

// USDT is the BSC address on both: the shared anvil has a mock etched there.
const USDT = "0x55d398326f99059fF775485246999027B3197955";

// Anvil values come from chain/deployments/zyqorix.31337.json.
const ADDRESSES = {
  31337: { usdt: USDT, accounts: "0xab56D1258e3666f8d315db1cfd49F8f402d995Ec", gateway: "0xDCF79230C7954Af96f540f7CF7e430AFC7b0B595", register: "0x30e41Ca2C80964eb88c22c860179bB8d230f3b24", rewards: "0xd7a89AEa304A491Ef4B5e74928370059fa53D8C6" },
  56: { usdt: USDT, accounts: "", gateway: "", register: "", rewards: "" },
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
];

const view = (name, inputs, outputs) => ({ type: "function", name, stateMutability: "view", inputs, outputs });
const write = (name, inputs = []) => ({ type: "function", name, stateMutability: "nonpayable", inputs, outputs: [] });
const uint = (name = "") => ({ name, type: "uint256" });
const user = { name: "user", type: "address" };

export const REWARDS_ABI = [
  view("DAY", [], [uint()]),
  view("isActive", [user], [{ name: "", type: "bool" }]),
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

export const GATEWAY_ABI = [
  view("minDeposit", [], [uint()]),
  view("coolDown", [user], [uint()]),
  write("withdrawAgent", [uint("amount")]),
  write("deposit", [{ name: "tokenAddress", type: "address" }, uint("amount")]),
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
