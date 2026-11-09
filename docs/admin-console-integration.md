# Contract Integration: Admin console (all ZYQORIX contracts)

Built from `templates/contract-integration-template.md`, following `references/sops/smart-contract-integration.md`.

## 1. Contract
- **Name:** ZyqorixAccounts, ZyqorixGateway, ZyqorixFunder, ZyqorixRewards, ZyqorixRegister, ZyqorixVesting, ZyqorixLiquidity, ZyqorixToken
- **Network(s):** anvil 31337 (NAS testnet). BSC 56 addresses are empty until mainnet, and the tiles there show greyed out.
- **Address(es):** `chain/deployments/zyqorix.31337.json`, mirrored in `app/src/config/contracts.js`
- **Key functions (read):** every `view`/`pure` function. Functions without inputs load together under State; functions with inputs have a Query form.
- **Key functions (write):** every state-changing function. Owner and admin checks stay on-chain: the gas estimate runs first, so a call the wallet can't make shows the contract's reason before anything is signed.
- **Events to listen for:** none in the console. Receipts link to the testnet explorer.

## 2. ABI
- **Source artifact:** `cd chain && forge inspect src/zyqorix/<file>.sol:<Contract> abi --json`
- **Stored at:** `app/src/config/abi/<file>.json`. Regenerate after any contract change and redeploy.
- **Functions/events kept:** the full ABI.

## 3. Addresses / Config
- `app/src/config/contracts.js`: `ADDRESSES[chainId]` covers accounts, gateway, register, rewards, funder, vesting, liquidity and zqr.
- `app/src/config/adminContracts.js` lists the console tiles (slug, label, ABI, address, icon). It also holds `IRREVERSIBLE`: writes that need a tick-box before Send.

## 4. Hooks
- [x] **Read:** `hooks/useAdminContract.js` gives `values` (no-input reads, refreshed every 15s, pending block on anvil), `reads`, `writes` and `query(fn, args)`.
- [x] **Write:** `hooks/useTxAction.js` follows the SOP lifecycle: signing → pending → success or error, with a Wait/Cancel prompt after 60s and gas padded 30%.
- [x] **Loading / error / pending-tx handling:** contract revert reasons go through `lib/tx.js` `reason()`.

## 5. UI
- [x] `/admin` shows a grid of tiles in the Home quick-action style. `/admin/:slug` (`pages/AdminContract.jsx`) has Read and Write tabs and a function filter.
- [x] **Conversion bridge:**
  - Inputs stay strings. Each uint input has an `18 dp` / `raw` toggle: amount-like names default to 18 dp and go through `parseEther` at send time; bps, counts and seconds stay raw.
  - Outputs: amounts of 0.001 tokens or more show formatted, with the raw value below.
- [x] Pending, success and error states show on `components/TxButton.jsx`. Actions are disabled while a transaction is in flight.

## Token approvals (added 2026-11-02)
These functions pull tokens with `transferFrom`, found by grepping the `.sol` sources. Each needs an ERC-20 allowance first. Calling them without one reverted `TRANSFER_FROM_FAILED`.

| Function | Token | Payer (owner) | Spender |
|---|---|---|---|
| `gateway.deposit` | `tokenAddress` (USDT) | caller | gateway |
| `gateway.depositFor` | `tokenAddress` (USDT) | `user` | gateway |
| `gateway.depositTo` | `tokenAddress` (USDT) | caller (signer); `user` only receives the credit | gateway |
| `funder.fundRewards` | USDT | caller | funder |
| `liquidity.addLiquidityUSDT`, `swapUSDTToToken`, `depositUSDT` | USDT | caller | liquidity |
| `liquidity.depositToken` | ZQR | caller | liquidity |
| `register.register` | USDT (`initialDeposit`) | caller | **gateway** (pulled through `depositFor`) |
| `zqr.burnFrom`, `zqr.transferFrom` | ZQR | `account` / `from` | caller |

- **Config:** `APPROVALS` in `config/adminContracts.js` maps each function to its token, payer, spender and amount. `hooks/useApproval.js` reads the allowance, the payer's balance and the token symbol.
- **Console behaviour:** the write card shows how much is needed, the current allowance and the payer's balance.
  - When the connected wallet pays, an Approve button appears for the exact amount.
  - When someone else pays, it says that wallet must approve first.
  - Send stays disabled until the allowance and balance are enough.
- **Member pages:** the Register page and the Deposit sheet already approve the gateway before sending.

## Configuration checklist (added 2026-11-02)
- `/admin` shows a Configuration section below the tiles: one card per contract listing every wiring call it needs, read back from chain in one multicall (refreshed every 15s).
- A green check means the getter returns the expected address or value. A red cross means not set, with the call that fixes it underneath. A read that reverts counts as not set.
- Launch locks (`liquidity.lockLiquidity`, `gateway.lockFunder`) show an amber cross and aren't counted in "N of M wiring steps set": they are one-way and go last.
- Items live in `config/adminChecklist.js` (`read: [slug, fn, args]`, `ok(value)`, `fix`, `launch`). "Router approved" reads the USDT allowance from liquidity to `CONTRACTS.swapRouter`, because liquidity's router getter is private. It's hidden while `swapRouter` is empty (BSC today).
- Testnet on 2026-11-02 read 18 of 19 set, matching `cast call`. The only cross is `liquidity.tradingWallet`, which only the SEND_TO_WALLET mode needs.

## Pre-Deploy
- [ ] **Security review:** no contract changes. The console can only do what the wallet is allowed to do on-chain.
- [x] **Happy and failure paths tested on testnet (2026-11-02, owner wallet):**
  - Gateway state reads
  - `isAllowedDenomination(50)` → true
  - `setMinDeposit(50)` confirmed on-chain, with no change in value
  - `lockFunder` Send stays disabled until the tick-box is checked
  - `accounts.addUser` with an existing member shows "This wallet is already registered." before signing
  - A bad address is rejected in the form
  - `gateway.deposit(USDT, 50)`: Send disabled at 0 allowance → Approve 50 USDT confirmed → deposit confirmed
  - `depositFor` with another payer: Send disabled, with a "must approve first" message
  - `register.register`: Approve targets the gateway
- [x] Decision logged in `decisions/log.md`.
