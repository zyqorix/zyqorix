# ZYQORIX: BSC mainnet deployment in Remix (task list)

**Date:** 2026-11-09 · **Source:** commit `7153005` on `zyqorix/zyqorix` main, folder `contracts/` · **Full runbook:** `DEPLOY-MAINNET.md`
**Network:** BNB Smart Chain mainnet (chain 56) · **You deploy and sign every transaction; Claude only checks with read-only calls.**

After every deploy or call: send Claude the address or the transaction hash. Tick ☐ only after Claude confirms it.

---

## A. Before you start

- ☐ A1 **Wallets ready:**
  - **Root/owner wallet:** deploys every contract. It becomes the permanent root of the member tree and can never move.
  - **Exchanger wallets:** the client's wallets.
  - **Funding wallets:** at most 5. None of them may also be an exchanger wallet.
  - **Multisig (Safe):** created on BNB Smart Chain, for step 11.3.
- ☐ A2 Root wallet holds **at least 0.3 BNB** for gas, plus the liquidity seed in USDT and ZQR (step 3.6).
- ☐ A3 Use a **private RPC** in the wallet (e.g. a MEV-protected BSC RPC) for the liquidity seed in 3.6.
- ☐ A4 In Remix, open the `contracts/` files from commit `7153005`. For the exchanger, use `deploy/ExchangerDisbursement.flat.sol`: it is the same code with the OpenZeppelin imports inlined, and it compiles to the same bytecode.
- ☐ A5 **Remix compiler settings, the same for every contract:**
  - compiler **0.8.38**;
  - optimization **on, 200 runs**;
  - **via-IR off**;
  - the same EVM version every time (the default is fine).
- ☐ A6 In the Deploy tab:
  - Environment = **Injected Provider (MetaMask)**;
  - MetaMask shows **BNB Smart Chain** and the **root wallet**;
  - in the CONTRACT dropdown, pick the main contract named in each step, never an interface.

---

## Step 0. Retire the old stack (old contracts)

Sign every call in this step, and step 4.3, with the old owner wallet `0x1fEbd3081F8874c8474C5Da68F8fc1C0BE7a2414`. Read on chain 2026-11-09:

| Contract | State |
|---|---|
| Old gateway | not paused |
| Old accounts | not paused |
| Old liquidity | not locked, position 7750752 open |
| Old vesting | holds 501M ZQR, not migrated |

| ☐ | Call | Check |
|---|---|---|
| ☐ 0.1 | Old gateway `0x335Ffb932dd7729CfeCEF803ED5C0C44CB5b0d60` → `setPaused(true)` | `paused()` = true |
| ☐ 0.2 | Old accounts `0xAB26C1ffcF3Ef20d53a12dd3B99850B376e68c45` → `setPaused(true)` | `paused()` = true |
| ☐ 0.3 | Old liquidity `0xb0EB2Dd04f943B4466EA95A19671E8da579651E5` → `emergencyWithdraw()`, then `tokenWithdraw()` | `TOKENID()` = 0, USDT and ZQR back in the root wallet |

The old vesting's 501M ZQR moves in step 4.2.

---

## Step 1. accounts.sol → contract `ZyqorixAccounts`

- ☐ 1.1 Deploy with no arguments `()`.
- ☐ 1.2 Verify on BscScan and send the address. Check: `owner()` = `root()` = root wallet.

## Step 2. ExchangerDisbursement.flat.sol → contract `ExchangerDisbursement`

- ☐ 2.1 Deploy `(OWNER)` = the root wallet address.
- ☐ 2.2 Verify and send the address. Check: `owner()` = root wallet.
- ☐ 2.3 `addExchanger(wallet)` once for each exchanger wallet. Check: `exchangerCount()`.

## Step 3. liquidity.sol → contract `ZyqorixLiquidity`

- ☐ 3.1 Deploy `(0x46A15B0b27311cedF172AB29E4f4766fbE7F4364, 0x1b81D678ffb9C0263b24A97847620C99d213eB14)` (position manager, router).
- ☐ 3.2 Verify and send the address.
- ☐ 3.3 `initializePool(0xDac4D29e16b87e3D48c80CC569e8040C454582BF)`. Check: `FEE()` = 10000.
- ☐ 3.4 `initializeApproval()`.
- ☐ 3.5 `growObservationCardinality`, called 4 times: **1200**, then **2200**, **3200**, **4100**.
- ☐ 3.6 `setTradingWallet(EXCHANGER)`.
- ☐ 3.7 Seed the position, through the **private RPC**. In the USDT and ZQR token contracts, `approve(LIQUIDITY, amount)` first, then:
  1. `depositUSDT(amount)`;
  2. `depositToken(amount)`;
  3. `initializePosition()`.

  Check: `TOKENID()` > 0.
- ☐ 3.8 After 30 minutes, Claude checks `convertToken(USDT, 1e18)` > 0.

## Step 4. vesting.sol → contract `ZyqorixVesting`

- ☐ 4.1 Deploy `(ACCOUNTS, 2592000)`.
- ☐ 4.2 Verify and send the address. Check: `MONTH()` = 2592000.
- ☐ 4.3 Old vesting `0x60818CdD14951E2e3e91054AD9696b31A2d3018c` → `emergencyWithdraw(VESTING)`. Check: new `available()` ≈ 501M ZQR.

## Step 5. funder.sol → contract `ZyqorixFunder`

- ☐ 5.1 Deploy `(ACCOUNTS)`.
- ☐ 5.2 Verify and send the address.
- ☐ 5.3 `setTradingWallet(EXCHANGER)`. Check: `tradingWallet()` = EXCHANGER.

## Step 6. gateway.sol → contract `ZyqorixGateway`

- ☐ 6.1 Deploy `(ACCOUNTS, FUNDER)`.
- ☐ 6.2 Verify and send the address. Check: `funder()` = FUNDER.
- ☐ 6.3 On the funder: `setGateway(GATEWAY)`.
- ☐ 6.4 On the gateway: `setLiquidity(LIQUIDITY)`.

## Step 7. rewards.sol → contract `ZyqorixRewards`

- ☐ 7.1 Deploy `(ACCOUNTS, GATEWAY, VESTING, 86400)`. **GATEWAY can never change here, so it must be the step 6 address.**
- ☐ 7.2 Verify and send the address. Check: `DAY()` = 86400, `floorPrice()` = `lastPrice()` = 1e15.
- ☐ 7.3 On the gateway: `setRewards(REWARDS)`.
- ☐ 7.4 On the funder: `setRewards(REWARDS)`. Do this **only after 7.3**.
- ☐ 7.5 On accounts: `addAdmin(REWARDS)`.

## Step 8. register.sol → contract `ZyqorixRegister`

- ☐ 8.1 Deploy `(ACCOUNTS, GATEWAY)`.
- ☐ 8.2 Verify and send the address. Check: `initialDeposit()` = 50 USDT.
- ☐ 8.3 On accounts: `addAdmin(REGISTER)`.

---

## Step 9. Funding wallets

- ☐ 9.1 On the funder: `addFundingWallet(wallet)`, once per wallet (at most 5). Never use an exchanger wallet.
- ☐ 9.2 Each funding wallet approves the funder on zyqorix.net `/fund`.

## Step 10. App cutover (Claude, on your OK)

- ☐ 10.1 Claude puts all 8 addresses into the app (chain 56) and switches it back from testnet to mainnet. The `appkit.js` line 29 override gets restored here.
- ☐ 10.2 `/admin` → Configuration: every required row is green.
- ☐ 10.3 Claude publishes zyqorix.net. Then a small live test:
  1. register (50 USDT);
  2. activate $50;
  3. withdraw 20.

## Step 11. Launch locks and multisig (before real deposits)

- ☐ 11.1 On liquidity: `lockLiquidity()`.
- ☐ 11.2 On the gateway: `lockFunder()`, **only after 11.1**.
- ☐ 11.3 Hand ownership to the Safe, in this order:
  1. Send Claude the Safe address. Claude checks that it exists on BSC.
  2. Optional: `accounts.addAdmin(OPS)` for a day-to-day wallet, done **before** the handover. Admins can also call `funder.sendToTrading`, so add only a wallet you trust with the treasury.
  3. `accounts.transferOwnership(SAFE)`, then in the Safe (Transaction Builder) run `accounts.acceptOwnership()`. Check: `owner()` = SAFE and `root()` = root wallet.
  4. Only after step 3 works:
     - `liquidity.transferOwnership(SAFE)`;
     - `exchanger.transferOwnership(SAFE)`.

     Both take effect at once, so copy the exact address from step 3. **Never call `renounceOwnership`.**

---

**Disclosure on the site:** members are told that 60% of each activation goes to trading, and that the owner and admins can send treasury USDT to the trading wallet (FAQ "Who controls the treasury?").
**If anything looks wrong:** stop, call `setPaused(true)` on the new gateway, and send Claude the transaction hash.
