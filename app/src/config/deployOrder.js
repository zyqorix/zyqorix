// Mainnet deploy order on /admin, top to bottom (projects/zyqorix/DEPLOY-MAINNET.md). Every contract is deployed
// fresh in Remix with solc 0.8.38, optimizer on, 200 runs, no via-IR. A step shows as done once contracts.js holds
// an address for it that differs from the retired one.
export const REMIX_SETTINGS = "Remix: solc 0.8.38 · optimizer on, 200 runs · no via-IR · source projects/zyqorix/contracts";

const PANCAKE_POSITION_MANAGER = "0x46A15B0b27311cedF172AB29E4f4766fbE7F4364";
const PANCAKE_SWAP_ROUTER = "0x1b81D678ffb9C0263b24A97847620C99d213eB14";
const ZQR_POOL = "0xDac4D29e16b87e3D48c80CC569e8040C454582BF";

export const DEPLOY_ORDER = [
  {
    step: 0, label: "Retire the 11-03 stack", file: null, args: null,
    tasks: [
      "old gateway 0x335F: setPaused(true)",
      "old accounts 0xAB26: setPaused(true)",
      "old liquidity 0xb0EB: emergencyWithdraw(), then tokenWithdraw()",
    ],
  },
  {
    step: 1, slug: "accounts", label: "Accounts", file: "accounts.sol", contract: "ZyqorixAccounts", args: "()",
    note: "Deploy from the root wallet: root can never move.",
    tasks: ["Send the address · check owner() = root() = deployer"],
  },
  {
    step: 2, slug: "exchanger", label: "Exchanger", file: "exchangerdisbursement.sol", contract: "ExchangerDisbursement", args: "(owner)",
    tasks: ["addExchanger(wallet) for each client exchanger wallet, never a funding wallet"],
  },
  {
    step: 3, slug: "liquidity", label: "Liquidity", file: "liquidity.sol", contract: "ZyqorixLiquidity", args: `(${PANCAKE_POSITION_MANAGER}, ${PANCAKE_SWAP_ROUTER})`,
    tasks: [
      `initializePool(${ZQR_POOL})`,
      "initializeApproval()",
      "growObservationCardinality: 1200, 2200, 3200, then 4100",
      "setTradingWallet(exchanger)",
      "depositUSDT + depositToken, then initializePosition() (private RPC)",
      "wait 30 minutes for the TWAP",
    ],
  },
  {
    step: 4, slug: "vesting", label: "Vesting", file: "vesting.sol", contract: "ZyqorixVesting", args: "(accounts, 2592000)",
    tasks: ["old vesting 0x6081: emergencyWithdraw(new vesting), moves the 501M ZQR"],
  },
  {
    step: 5, slug: "funder", label: "Funder", file: "funder.sol", contract: "ZyqorixFunder", args: "(accounts)",
    tasks: ["funder.setTradingWallet(exchanger)"],
  },
  {
    step: 6, slug: "gateway", label: "Gateway", file: "gateway.sol", contract: "ZyqorixGateway", args: "(accounts, funder)",
    tasks: ["funder.setGateway(gateway)", "gateway.setLiquidity(liquidity) · slippage stays 300"],
  },
  {
    step: 7, slug: "rewards", label: "Rewards", file: "rewards.sol", contract: "ZyqorixRewards", args: "(accounts, gateway, vesting, 86400)",
    note: "The gateway is fixed for good: use the step 6 address.",
    tasks: ["gateway.setRewards(rewards)", "funder.setRewards(rewards), after gateway.setRewards", "accounts.addAdmin(rewards)"],
  },
  {
    step: 8, slug: "register", label: "Register", file: "register.sol", contract: "ZyqorixRegister", args: "(accounts, gateway)",
    note: "The gateway is fixed for good: use the step 6 address.",
    tasks: ["accounts.addAdmin(register) · initialDeposit stays 50 USDT"],
  },
  {
    step: 9, label: "Funding wallets", file: null, args: null,
    tasks: ["funder.addFundingWallet(wallet), up to 5, none an exchanger", "each funding wallet approves the funder on /fund"],
  },
  {
    step: 10, label: "Switch the app", file: null, args: null,
    tasks: ["send all 8 addresses to update contracts.js and republish", "every Configuration row below green · small live test"],
  },
  {
    step: 11, label: "Launch locks", file: null, args: null,
    tasks: ["liquidity.lockLiquidity()", "gateway.lockFunder(), after lockLiquidity", "ownership of accounts, exchanger and liquidity to a multisig"],
  },
];
