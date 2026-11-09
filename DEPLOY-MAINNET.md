# ZYQORIX: BSC mainnet deployment runbook (ground zero, all fresh on 0.8.38)

**Prepared:** 2026-11-07, **updated 2026-11-09** · **Decision:** redeploy every ZYQORIX contract fresh on solc 0.8.38, keep the ZQR token.
**Source changes since 2026-11-07** (all in `projects/zyqorix/contracts/`, tested and on the NAS rehearsal unless noted):
- **rewards.sol (2026-11-08):** tier days count from the member's first activation; members activate from their whole wallet balance. Deposits are spent first; a part paid from rewards draws 80% of itself (60% trading + 20% liquidity) from the reward pool, first come first served, and its referral, agent and leadership shares are paid as reward credit. Audited GO. Live on the NAS at `0x3195…b890`.
- **funder.sol (2026-11-09, owner decision):** the accounts owner **and any admin** may call `sendToTrading(amount)` as well as rewards (error `NOT_AUTH` for anyone else). It moves funder USDT (which includes member deposits) to the trading wallet and counts it in `tradingCapitalOut`. **Not on the NAS funder yet.** See Step 5.
**Deployer:** the owner, in Remix (https://app.remix.live/). **Deploy accounts from the wallet that must be root:** root is the top of the tree and can never move.
**Remix settings for every contract:** solc **0.8.38**, optimizer **on, 200 runs**, same EVM version for all, no via-IR. Source: `projects/zyqorix/contracts/`.
**Why 0.8.38:** BscScan flags 0.8.37 for the low-severity bug SOL-2026-7 (YulOptimizerKnowledgeBaseStaleBookkeeping), which 0.8.38 fixes. Every contract pins exactly `pragma solidity 0.8.38;` (only zqrtoken.sol keeps a range, since ZQR is not redeployed). All 305 tests pass on 0.8.38. Runtime sizes at 200 runs, no via-IR, EVM shanghai or later (measured 2026-11-09): accounts 5,096 B, liquidity 16,252 B, vesting 4,428 B, exchanger 3,052 B, funder 7,206 B, gateway 11,673 B, rewards 19,905 B, register 1,639 B (limit 24,576). On EVM paris, rewards is 20,307 B, still under the limit.
**After each contract:** verify it on BscScan and send Claude the address. Claude compares the on-chain code to the 0.8.38 build and confirms each task with a read-only `cast call`. Tick ☐ only when the check matches.

## Deployment order at a glance

| # | Contract | Status | Constructor | Address |
|---|---|---|---|---|
| — | ZQR token | ✅ **Kept, unchanged** | — | `0x43ADE7aE5E14e6dadD0f6967a0aDEADe56095e70`. ✅ Checked 2026-11-07: ownership renounced, ~1B supply, owner holds 498.9M, old vesting 501M |
| — | USDT, PancakeSwap V3 | ✅ External | — | USDT `0x55d3…7955`, position manager `0x46A1…4364`, router `0x1b81…eB14`, ZQR/USDT 1% pool `0xDac4…82BF` (reused) |
| 0 | **Retire the 11-03 stack** | ☐ Do first | — | Step 0 |
| 1 | accounts | ☐ NEW | `()` | |
| 2 | exchanger | ☐ NEW | `(owner)` | |
| 3 | liquidity | ☐ NEW | `(0x46A15B0b27311cedF172AB29E4f4766fbE7F4364, 0x1b81D678ffb9C0263b24A97847620C99d213eB14)` | |
| 4 | vesting | ☐ NEW | `(ACCOUNTS, 2592000)` | |
| 5 | funder | ☐ NEW | `(ACCOUNTS)` | |
| 6 | gateway | ☐ NEW | `(ACCOUNTS, FUNDER)` | |
| 7 | rewards | ☐ NEW | `(ACCOUNTS, GATEWAY, VESTING, 86400)` | |
| 8 | register | ☐ NEW | `(ACCOUNTS, GATEWAY)` | |
| — | Wallets, app, locks | ☐ After all 8 | — | Steps 9–11 |

**Price:**
- The floor and the starting last price are both **$0.001** per ZQR. Both are the rewards defaults (`floorPrice = lastPrice = 1e15`), so no call is needed.
- After that, rewards updates `lastPrice` by itself from the 30-minute pool TWAP on each activation.
- The pool keeps its current price (about $0.00183). The new liquidity contract seeds at that price.

```bash
# read-back helpers (Claude runs these; read-only)
R=https://bsc-dataseed.bnbchain.org
USDT=0x55d398326f99059fF775485246999027B3197955  ZQR=0x43ADE7aE5E14e6dadD0f6967a0aDEADe56095e70  POOL=0xDac4D29e16b87e3D48c80CC569e8040C454582BF
OLD_ACCOUNTS=0xAB26C1ffcF3Ef20d53a12dd3B99850B376e68c45 OLD_GATEWAY=0x335Ffb932dd7729CfeCEF803ED5C0C44CB5b0d60
OLD_LIQUIDITY=0xb0EB2Dd04f943B4466EA95A19671E8da579651E5 OLD_VESTING=0x60818CdD14951E2e3e91054AD9696b31A2d3018c
ACCOUNTS= EXCHANGER= LIQUIDITY= VESTING= FUNDER= GATEWAY= REWARDS= REGISTER=   # filled in as deployed
```

---

## Step 0: retire the 11-03 stack and recover its funds (old contracts, owner wallet)
- ☐ 0.1 `gateway(OLD_GATEWAY).setPaused(true)`. Check: `paused()` = true.
- ☐ 0.2 `accounts(OLD_ACCOUNTS).setPaused(true)`: no more sign-ups on the old tree. Check: `paused()` = true.
- ☐ 0.3 `liquidity(OLD_LIQUIDITY).emergencyWithdraw()`: closes the old position (about 74 USDT and 35k ZQR) and sends it to the owner. Then `tokenWithdraw()` for any leftovers. Check: `TOKENID()` = 0.
- Old vesting's 501M ZQR moves in Step 4.4, once the new vesting exists.
- The old funder's 17 USDT of test money stays there: its rescue function blocks the payment token.

## Step 1: accounts: deploy `ZyqorixAccounts()` from the root wallet
- ☐ 1.1 Verify on BscScan and send Claude the address. Check: `owner()` = `root()` = the deployer.

## Step 2: exchanger: deploy `ExchangerDisbursement(owner)`
- ☐ 2.1 Verify and send the address. Check: `usdt()` = USDT, `owner()` = owner.
- ☐ 2.2 `addExchanger(e)` for each of the client's exchanger wallets. Check: `exchangerCount()`.
  - **Rule:** an exchanger wallet can never also be a funding wallet (Step 9). Pick the owner wallet for one role only.

## Step 3: liquidity: deploy `ZyqorixLiquidity(positionManager, swapRouter)`
- ☐ 3.1 Verify and send the address. Check: `TOKEN()` = ZQR, `USDT()` = USDT.
- ☐ 3.2 `initializePool(POOL)`. Check: `FEE()` = 10000.
- ☐ 3.3 `initializeApproval()`. Check: `USDT.allowance(LIQUIDITY, router)` > 0.
- ☐ 3.4 `growObservationCardinality(next)` with next = **1200**, then **2200**, **3200**, **4100**. This is pool state. Check: the 5th value of `pool.slot0()` ≥ 4100.
- ☐ 3.5 `setTradingWallet(EXCHANGER)`. Check: `tradingWallet()` = EXCHANGER.
- ☐ 3.6 Seed the position at the current price:
  1. approve and `depositUSDT(amount)`;
  2. approve and `depositToken(amount)`;
  3. `initializePosition()`.
  - **Send the seed through a private RPC** so it can't be sandwiched.
  - Check: `TOKENID()` > 0.
- ☐ 3.7 After 30 minutes: `convertToken(USDT, 1e18)` > 0 (about 545 ZQR per USDT at $0.00183).

## Step 4: vesting: deploy `ZyqorixVesting(ACCOUNTS, 2592000)`
- ☐ 4.1 Verify and send the address. Check: `MONTH()` = 2592000, `vestingMonths()` = 60.
- ☐ 4.2 Fund it from the old vesting: `vesting(OLD_VESTING).emergencyWithdraw(VESTING)`. This sends all 501M ZQR across in one call. The old accounts owner must sign it, and that is the same owner wallet. Check: new `available()` = 501M; old `migratedTo()` = VESTING.

## Step 5: funder: deploy `ZyqorixFunder(ACCOUNTS)`
- ☐ 5.1 Verify and send the address.
- ☐ 5.2 `setTradingWallet(EXCHANGER)`. Check: `tradingWallet()` = EXCHANGER.
- **Owner and admin power:** the accounts owner or any admin (`accounts.addAdmin`) can call `funder.sendToTrading(amount)` at any time, for any amount the funder holds. That includes member deposits, so a large send can leave the funder unable to pay withdrawals until trading returns funds. Use it only for trading capital you mean to move, and keep the owner key safe until 11.3 moves it to a multisig. Every admin wallet holds this power too, so add plain-wallet admins only if you trust them with the treasury.
  - **Not capped to the surplus (owner decision 2026-11-09, audit M-1 accepted, disclosure only).** A send larger than the funder's spare USDT leaves `rewardPool` booked higher than the USDT backing it, so later reward withdrawals are paid from member deposits until the funder runs dry. Spare USDT = funder balance − (`totalWalletBalance` − `totalRewardCredit`) − (`totalAgentBalance` − `totalAgentCredit`) − (`leadershipPool` − `leadershipCredit`) − `rewardPool`; Claude can read it before any send. Disclosed to members in the FAQ ("Who controls the treasury?").

## Step 6: gateway: deploy `ZyqorixGateway(ACCOUNTS, FUNDER)`
- ☐ 6.1 Verify and send the address. Check: `funder()` = FUNDER, `liquiditySlippageBps()` = 300.
- ☐ 6.2 `funder.setGateway(GATEWAY)`. Check: `funder.gateway()` = GATEWAY.
- ☐ 6.3 `gateway.setLiquidity(LIQUIDITY)`. Check: `gateway.liquidity()` = LIQUIDITY.

## Step 7: rewards: deploy `ZyqorixRewards(ACCOUNTS, GATEWAY, VESTING, 86400)`
GATEWAY is locked in for good, so it must be the Step 6 address. This is the 2026-11-08 rewards: tier days from the first activation, and activation from the whole wallet (deposits first; a rewards-paid part needs 80% of itself in the reward pool).
- ☐ 7.1 Verify and send the address. Check: `gateway()`, `vesting()`, `DAY()` = 86400, `floorPrice()` = `lastPrice()` = 1e15 ($0.001).
- ☐ 7.2 `gateway.setRewards(REWARDS)`. Check: `gateway.rewards()` = REWARDS.
- ☐ 7.3 `funder.setRewards(REWARDS)`, **only after 7.2**. Check: `funder.rewards()` = REWARDS.
- ☐ 7.4 `accounts.addAdmin(REWARDS)`. Check: `isAdmin(REWARDS)` = true.

## Step 8: register: deploy `ZyqorixRegister(ACCOUNTS, GATEWAY)`
- ☐ 8.1 Verify and send the address. Check: `gateway()` = GATEWAY, `initialDeposit()` = 50 USDT (anti-spam).
- ☐ 8.2 `accounts.addAdmin(REGISTER)`. Check: `isAdmin(REGISTER)` = true.

---

## Step 9: funding wallets
- ☐ 9.1 `funder.addFundingWallet(w)` for each client funding wallet (at most 5). For each wallet: `exchanger.isExchanger(w)` must be false, and it must not equal `liquidity.tradingWallet()`.
- ☐ 9.2 Each funding wallet approves the new funder on zyqorix.net `/fund`. Check: `USDT.allowance(w, FUNDER)` > 0.

## Step 10: app cutover (Claude, publish on your OK)
- ☐ 10.1 Claude:
  - puts all 8 addresses into `app/src/config/contracts.js` (chain 56) and `chain/deployments/zyqorix.56.json`;
  - lists the 11-03 contracts as `retired`.
- ☐ 10.2 `/admin` → Configuration: every required row is green, including the retired rows (old gateway and accounts paused, old position withdrawn, old vesting migrated).
- ☐ 10.3 Republish zyqorix.net. Then a small live test:
  1. register (50 USDT);
  2. activate the $50 tier;
  3. withdraw a small amount.
  - Old members (one test wallet, 0x7E4A) register again on the new tree.

## Step 11: launch locks (one-way, before real deposits)
- ☐ 11.1 `liquidity.lockLiquidity()`. Check: `liquidityLocked()` = true.
- ☐ 11.2 `gateway.lockFunder()`, **after 11.1**. Check: `funderLocked()` = true.
- ☐ 11.3 Move ownership of accounts (covers funder, gateway, rewards, register and vesting), the exchanger and liquidity to a multisig. This moves the owner's `funder.sendToTrading` power (Step 5) behind the multisig; admins keep it, so the multisig protects it only if no plain-wallet admin is added.
  Tested in Foundry (`test_multisigOwnershipHandover`, a contract owner with no receive()): members keep registering, activating, claiming and withdrawing; every owner call works through the multisig. Order:
  1. Create the Safe **on BNB Smart Chain** and send Claude its address. Claude checks it has code on chain 56.
  2. Optional: `accounts.addAdmin(OPS)` for a plain day-to-day wallet **while the old key still owns**. After the handover the old key is neither owner nor admin. Admin tasks (pause, agents, limits, prices, `setFunder` before 11.2, `withdrawFor`, **and `funder.sendToTrading`**) can run from OPS; owner tasks need the Safe.
  3. `accounts.transferOwnership(SAFE)`, then the Safe executes `accounts.acceptOwnership()` (Safe Transaction Builder). Two-step: nothing changes until the accept, and a wrong pending address can be overwritten. Check: `owner()` = SAFE, `root()` still = the deployer.
  4. Only after 3 succeeds, use the same proven address for the single-step ones: `liquidity.transferOwnership(SAFE)` and `exchanger.transferOwnership(SAFE)`. These take effect at once: a typo loses them for good. **Never call `exchanger.renounceOwnership()`.**
  - After the handover, liquidity fees and withdrawals (`collectFees`, `emergencyWithdraw`, `tokenWithdraw`) pay USDT and ZQR to the Safe. Root stays the deployer wallet for good (top of the tree; it earns as a sponsor), so keep that key too.
  - Owner-only actions on zyqorix.net (`/admin`, `/fund` funding wallets) need the Safe connected through WalletConnect; the Safe Transaction Builder is the dependable route.

## If something goes wrong
- **Before 11.2**, every link can be changed again.
- **A wrong gateway** in rewards or register means redeploying that contract.
- **When unsure,** pause the new gateway (`setPaused(true)`) before investigating.
- **The old stack is paused but not destroyed,** so its records stay readable on BscScan.
