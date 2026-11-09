// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

/*
 * ZYQORIX — Gateway Module
 * The single entry point for deposits and withdrawals. Deposits go straight from the user to the funder.
 * On a withdrawal the funder sends the gross amount here, and within that transaction the gateway pays
 * the user, swaps the fee through the liquidity contract and burns the tokens received. It ends every
 * transaction with a zero balance and tracks no balances: the rewards contract holds the wallet balance
 * record and the funder holds the assets. Replaces COC's assets vault.
 */

/* -------------------------------------------------------------------------- */
/*                        IERC20 (minimal BEP20 interface)                    */
/* -------------------------------------------------------------------------- */
/// @title IERC20
/// @notice The subset of the BEP20 / ERC20 interface this contract uses.
interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function approve(address spender, uint256 value) external returns (bool);
}

/// @title IERC20Burnable
/// @notice The optional burn function on the swapped token.
interface IERC20Burnable {
    function burn(uint256 amount) external;
}

/* -------------------------------------------------------------------------- */
/*                    IZyqorixAccounts (single source of truth)               */
/* -------------------------------------------------------------------------- */
/// @title IZyqorixAccounts
/// @notice The membership + authority view this contract reads from the ZYQORIX accounts contract.
interface IZyqorixAccounts {
    /// @notice True if `account` is a registered user.
    function isUser(address account) external view returns (bool);
    /// @notice True if `account` is the accounts owner or an explicit admin.
    function checkIsAdmin(address account) external view returns (bool);
    /// @notice The accounts contract owner — the single highest authority.
    function owner() external view returns (address);
}

/* -------------------------------------------------------------------------- */
/*                               IZyqorixRewards                              */
/* -------------------------------------------------------------------------- */
/// @title IZyqorixRewards
/// @notice What the gateway needs from the rewards contract, which owns every balance record.
interface IZyqorixRewards {
    /// @notice The gateway the rewards contract accepts calls from.
    function gateway() external view returns (address);
    /// @notice The wallet balance recorded for `user`.
    function walletBalance(address user) external view returns (uint256);
    /// @notice The agent rewards recorded for `user`.
    function agentBalance(address user) external view returns (uint256);
    /// @notice Record a deposit in `user`'s wallet balance. Callable by the gateway.
    function creditDeposit(address user, uint256 amount) external;
    /// @notice Debit a gross withdrawal of `amount` from `user`'s wallet. Callable by the gateway.
    function debitWallet(address user, uint256 amount) external;
    /// @notice Whether `user` is currently an agent.
    function isAgent(address user) external view returns (bool);
    /// @notice Debit an agent withdrawal of `amount`. Callable by the gateway.
    function debitAgent(address user, uint256 amount) external;
}

/* -------------------------------------------------------------------------- */
/*                               IZyqorixFunder                               */
/* -------------------------------------------------------------------------- */
/// @title IZyqorixFunder
/// @notice The treasury the gateway draws on.
interface IZyqorixFunder {
    /// @notice The payment token this funder pays out.
    function token() external view returns (address);
    /// @notice The only address the funder lets call `pay`.
    function gateway() external view returns (address);
    /// @notice The rewards contract the funder works with.
    function rewards() external view returns (address);
    /// @notice The funder's trading wallet.
    function tradingWallet() external view returns (address);
    /// @notice Trading profit not yet claimed.
    function rewardPool() external view returns (uint256);
    /// @notice Pay `amount` of the token to `to`.
    function pay(address to, uint256 amount) external;
    /// @notice Book `amount` of the caller's token into the reward pool. The caller approves the funder.
    function fundRewards(uint256 amount) external;
    /// @notice Pull the funding wallets' approved USDT into the funder and book it. Permissionless.
    function pullFunding() external returns (uint256 amount);
}

/* -------------------------------------------------------------------------- */
/*                              IZyqorixLiquidity                             */
/* -------------------------------------------------------------------------- */
/// @title IZyqorixLiquidity
/// @notice The swap the gateway runs on the withdrawal fee.
interface IZyqorixLiquidity {
    /// @notice The stablecoin the liquidity contract swaps from.
    function USDT() external view returns (address);
    /// @notice True once its exit routes are closed for good.
    function liquidityLocked() external view returns (bool);
    /// @notice The position NFT id, 0 until it is minted.
    function TOKENID() external view returns (uint256);
    /// @notice The token it swaps to.
    function TOKEN() external view returns (address);
    /// @notice Pull `usdtAmount` from the caller, swap it, and send the token to `recipient`.
    /// @return amountOut The token amount delivered.
    function swapUSDTToToken(uint256 usdtAmount, uint24 slippageBps, address recipient, uint256 deadline)
        external returns (uint256 amountOut);
}

/* -------------------------------------------------------------------------- */
/*                       ReentrancyGuard (minimal, inlined)                   */
/* -------------------------------------------------------------------------- */
/// @title ReentrancyGuard
/// @author ZYQORIX
/// @notice Prevents nested (re-entrant) calls to functions marked `nonReentrant`.
abstract contract ReentrancyGuard {
    uint256 private _status = 1; // 1 = not entered, 2 = entered

    modifier nonReentrant() {
        require(_status == 1, "REENTRANCY");
        _status = 2;
        _;
        _status = 1;
    }
}

/* ========================================================================== */
/*                               ZyqorixGateway                               */
/* ========================================================================== */
/// @title ZyqorixGateway
/// @author ZYQORIX
/// @notice Takes user deposits and pays user withdrawals. A withdrawal is honored only when the rewards
///         contract shows enough withdrawable rewards AND the funder holds enough tokens. The withdrawal fee
///         is swapped through the liquidity contract and the tokens received are burned.
/// @dev Tracks no balances and keeps nothing between transactions. Deposits never pass through here;
///      withdrawals pass through within one transaction. Every balance record lives in the rewards contract.
contract ZyqorixGateway is ReentrancyGuard {
    /* ------------------------------- Wiring ---------------------------- */
    /// @notice The accounts contract — the single source of truth for isUser and authorization. Immutable.
    IZyqorixAccounts public immutable accounts;
    /// @notice The payment token: USDT at its BSC mainnet address. The anvil testnet has a mock there.
    address public constant token = 0x55d398326f99059fF775485246999027B3197955;
    /// @notice The current treasury. Changed by an admin with `setFunder` until `lockFunder`.
    IZyqorixFunder public funder;
    /// @notice True once `lockFunder` has fixed the funder and liquidity addresses for good.
    bool public funderLocked;
    /// @notice The rewards contract. Owner-set, relinkable. Deposits and withdrawals revert until set.
    IZyqorixRewards public rewards;
    /// @notice The contract that swaps withdrawal fees. Zero = fees go back to the funder.
    address public liquidity;
    /// @notice When true, deposits and withdrawals are blocked.
    bool public paused;

    /* ------------------------- Withdrawal limits ----------------------- */
    /// @notice Basis-points denominator (10000 = 100%).
    uint256 public constant BPS_DENOMINATOR = 10_000;
    /// @notice Highest allowed withdrawal fee (50%), so a bad setting can't zero out a withdrawal.
    uint256 public constant MAX_WITHDRAWAL_FEE = 5_000;
    /// @notice Gas the withdrawal must still hold when it tries the fee swap and burn. The swap runs inside a
    ///         try/catch, so without this floor a wallet's gas estimate settles on a limit where the swap runs out
    ///         of gas deep inside PancakeSwap and the fee silently stays in the funder (seen on BSC 2026-11-04:
    ///         a 6 USDT fee needed about 290k for the whole withdrawal and the wallet sent 342k).
    uint256 public constant FEE_SWAP_GAS = 450_000;
    /// @notice Gas held back from the fee swap so a swap that runs out of gas still leaves enough to book the fee
    ///         into the reward pool. Without it the swap gets 63/64 of what's left and the fallback can run dry,
    ///         reverting the whole withdrawal.
    uint256 public constant FEE_RETURN_GAS = 150_000;
    /// @notice Withdrawal fee in basis points. Starts at 10%.
    uint256 public withdrawal_fee = 1_000;
    /// @notice Smallest amount a member can `deposit`. Hub deposits through `depositFor` set their own amount.
    uint256 public minDeposit = 50 ether;
    /// @notice Slippage tolerance for the fee swap, in basis points. Starts at 3%.
    uint24 public liquiditySlippageBps = 300;
    /// @notice Per-account gate: block.timestamp must be GREATER than coolDown[account] to withdraw. Both
    ///         deposits and withdrawals reset it.
    mapping(address => uint256) public coolDown;
    /// @notice Seconds an account must wait between withdrawals. 0 disables the cooldown.
    uint256 public withdrawal_cooldown = 24 hours;
    /// @notice Smallest withdrawal (gross). Default 20 USDT.
    uint256 public withdrawalMin = 20 ether;
    /// @notice Largest withdrawal (gross). Default 100 USDT.
    uint256 public withdrawalMax = 100 ether;
    /// @notice Withdrawals must be a whole multiple of this. Default 20 USDT, so 20, 40, 60, 80 or 100.
    uint256 public withdrawalStep = 20 ether;

    /// @notice Where swapped tokens go when the token has no burn function.
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /* ------------------------------- Events ---------------------------- */
    /// @notice Emitted when `user`'s deposit lands in `funderAddr`.
    /// @param user The member credited.
    /// @param funderAddr The funder that received the tokens.
    /// @param amount The actual amount received.
    event Deposited(address indexed user, address indexed funderAddr, uint256 amount);
    /// @notice Emitted when `user` is paid from `funderAddr`.
    /// @param user The member paid.
    /// @param funderAddr The funder that paid.
    /// @param amount The gross amount debited from rewards.
    /// @param net The amount sent to the user (gross minus the fee).
    /// @param fee The withdrawal fee.
    /// @param burned The tokens bought with the fee and burned. 0 = the fee went back to the funder.
    event Withdrawn(address indexed user, address indexed funderAddr, uint256 amount, uint256 net, uint256 fee, uint256 burned);
    /// @notice Emitted when an agent withdraws agent rewards. There is no fee.
    /// @param user The agent.
    /// @param amount The amount paid.
    event AgentWithdrawn(address indexed user, uint256 amount);
    /// @notice Emitted when stray tokens are forwarded to the funder.
    /// @param token The token forwarded.
    /// @param amount The amount forwarded.
    event Swept(address indexed token, uint256 amount);
    /// @notice Emitted when the funder and liquidity addresses are fixed for good.
    event FunderLocked();
    /// @notice Emitted when the minimum deposit is changed.
    /// @param amount The new minimum.
    event MinDepositSet(uint256 amount);
    /// @notice Emitted when the funder is changed.
    /// @param funder The new funder.
    event FunderSet(address indexed funder);
    /// @notice Emitted when the rewards contract is changed.
    /// @param rewards The new rewards contract.
    event RewardsSet(address indexed rewards);
    /// @notice Emitted when the liquidity contract is changed.
    /// @param liquidity The new liquidity contract.
    event LiquiditySet(address indexed liquidity);
    /// @notice Emitted when the withdrawal fee is changed.
    /// @param feeBps The new fee in basis points.
    event WithdrawalFeeSet(uint256 feeBps);
    /// @notice Emitted when the fee swap slippage is changed.
    /// @param slippageBps The new slippage in basis points.
    event LiquiditySlippageSet(uint24 slippageBps);
    /// @notice Emitted when the pause flag is set.
    /// @param paused The new pause state.
    event PausedSet(bool paused);
    /// @notice Emitted when the withdrawal cooldown is changed.
    /// @param cooldown The new cooldown in seconds (0 = disabled).
    event WithdrawalCooldownSet(uint256 cooldown);
    /// @notice Emitted when the withdrawal amount rule is changed.
    /// @param min The smallest withdrawal.
    /// @param max The largest withdrawal.
    /// @param step Withdrawals must be a multiple of this.
    event WithdrawalLimitsSet(uint256 min, uint256 max, uint256 step);

    /* ------------------------------ Modifiers -------------------------- */
    /// @dev Restricts a function to the accounts OWNER. Reverts NOT_OWNER.
    modifier onlyOwner() {
        require(msg.sender == accounts.owner(), "NOT_OWNER");
        _;
    }

    /// @dev Restricts a function to the accounts owner or an explicit admin. Reverts NOT_AUTH.
    modifier onlyAuth() {
        require(accounts.checkIsAdmin(msg.sender), "NOT_AUTH");
        _;
    }

    /// @dev Blocks the guarded function while paused. Reverts PAUSED.
    modifier whenNotPaused() {
        require(!paused, "PAUSED");
        _;
    }

    /* ----------------------------- Constructor ------------------------- */
    /// @notice Deploy the gateway. Afterwards the owner calls `funder.setGateway(this)`.
    /// @param accountsAddr The deployed ZYQORIX accounts contract.
    /// @param funderAddr The initial funder; must pay out `token`.
    /// @dev Reverts ZERO_ADDRESS / NOT_CONTRACT (also when USDT has no code here) / FUNDER_TOKEN_MISMATCH.
    constructor(address accountsAddr, address funderAddr) {
        require(accountsAddr != address(0) && funderAddr != address(0), "ZERO_ADDRESS");
        require(accountsAddr.code.length > 0 && token.code.length > 0 && funderAddr.code.length > 0, "NOT_CONTRACT");
        require(IZyqorixFunder(funderAddr).token() == token, "FUNDER_TOKEN_MISMATCH");
        accounts = IZyqorixAccounts(accountsAddr);
        funder = IZyqorixFunder(funderAddr);
        emit FunderSet(funderAddr);
        emit WithdrawalLimitsSet(withdrawalMin, withdrawalMax, withdrawalStep);
    }

    /* ============================ USER — DEPOSIT ======================== */
    /// @notice Deposit `amount` of `tokenAddress`. The tokens go straight to the funder, the rewards contract
    ///         records them in your wallet balance, and your withdrawal cooldown restarts. Requires the caller
    ///         to be a registered member. Approve this contract on the token first.
    /// @param tokenAddress The payment token. Any other token is rejected, since wallet balances are USDT.
    /// @param amount The amount to pull from the caller.
    /// @dev Credits the ACTUAL amount received (funder balance delta), so fee-on-transfer tokens can't
    ///      over-credit. Reverts NOT_REGISTERED / ZERO_AMOUNT / BELOW_MIN_DEPOSIT / BAD_TOKEN / REWARDS_NOT_SET /
    ///      NOTHING_RECEIVED.
    function deposit(address tokenAddress, uint256 amount) external nonReentrant whenNotPaused {
        require(accounts.isUser(msg.sender), "NOT_REGISTERED");
        require(amount > 0, "ZERO_AMOUNT");
        require(amount >= minDeposit, "BELOW_MIN_DEPOSIT");
        require(tokenAddress == token, "BAD_TOKEN");
        require(address(rewards) != address(0), "REWARDS_NOT_SET");

        uint256 balBefore = IERC20(tokenAddress).balanceOf(address(funder));
        _safeTransferFrom(tokenAddress, msg.sender, address(funder), amount);
        uint256 received = IERC20(tokenAddress).balanceOf(address(funder)) - balBefore;
        require(received > 0, "NOTHING_RECEIVED");

        _creditDeposit(msg.sender, received);
    }

    /// @notice Pull `amount` of `tokenAddress` from `user` and credit `user`'s own wallet balance, so a hub
    ///         (e.g. register) can take an entry atomically. `user` approves THIS contract.
    /// @param user The member charged and credited.
    /// @param tokenAddress The payment token.
    /// @param amount The amount to pull.
    /// @dev onlyAuth. Reverts NOT_REGISTERED / ZERO_AMOUNT / BAD_TOKEN / REWARDS_NOT_SET / NOTHING_RECEIVED.
    function depositFor(address user, address tokenAddress, uint256 amount)
        external onlyAuth nonReentrant whenNotPaused
    {
        require(accounts.isUser(user), "NOT_REGISTERED");
        require(amount > 0, "ZERO_AMOUNT");
        require(tokenAddress == token, "BAD_TOKEN");
        require(address(rewards) != address(0), "REWARDS_NOT_SET");

        uint256 balBefore = IERC20(tokenAddress).balanceOf(address(funder));
        _safeTransferFrom(tokenAddress, user, address(funder), amount);
        uint256 received = IERC20(tokenAddress).balanceOf(address(funder)) - balBefore;
        require(received > 0, "NOTHING_RECEIVED");

        _creditDeposit(user, received);
    }

    /* ============================ USER — WITHDRAW ======================= */
    /// @notice Withdraw `amount` of your wallet balance to your wallet address, minus the withdrawal fee.
    /// @param amount The gross amount to debit from your wallet balance: from `withdrawalMin` to `withdrawalMax`, in
    ///        multiples of `withdrawalStep` (20, 40, 60, 80 or 100 USDT by default).
    function withdraw(uint256 amount) external nonReentrant whenNotPaused {
        _withdraw(msg.sender, amount);
    }

    /// @notice Run a withdrawal on `user`'s behalf. The tokens always go to `user`, under the same rules.
    /// @param user The member to pay.
    /// @param amount The gross amount to debit from `user`'s wallet balance.
    /// @dev onlyAuth.
    function withdrawFor(address user, uint256 amount) external onlyAuth nonReentrant whenNotPaused {
        _withdraw(user, amount);
    }

    /// @notice Withdraw `amount` of your agent rewards. Only a current agent can: a removed agent keeps the
    ///         balance but can't withdraw it unless nominated again. Cooldown applies; there is no fee or
    ///         allowed-amount rule, so you receive 100%.
    /// @param amount The amount to withdraw.
    /// @dev Reverts NOT_REGISTERED / ZERO_AMOUNT / REWARDS_NOT_SET / NOT_AGENT / INSUFFICIENT_AGENT /
    ///      INSUFFICIENT_FUNDER / COOLDOWN.
    function withdrawAgent(uint256 amount) external nonReentrant whenNotPaused {
        address user = msg.sender;
        require(accounts.isUser(user), "NOT_REGISTERED");
        require(amount > 0, "ZERO_AMOUNT");
        require(address(rewards) != address(0), "REWARDS_NOT_SET");
        require(rewards.isAgent(user), "NOT_AGENT");
        require(rewards.agentBalance(user) >= amount, "INSUFFICIENT_AGENT");
        _checkCooldown(user);

        rewards.debitAgent(user, amount);
        _requireFunderCovers(amount);
        funder.pay(user, amount);
        emit AgentWithdrawn(user, amount);
    }

    /* ============================== ADMIN ============================== */
    /// @notice Change the funder. New deposits and withdrawals use it immediately. This moves no USDT or ledger
    ///         and doesn't seal the old funder, so it's only for setup before any money arrives. There is no funder
    ///         migration: once the funder holds money it stays the funder.
    /// @param funderAddr The new funder. It must pay out `token` and already name this contract as its
    ///        gateway, so a bad address can't stop withdrawals.
    /// @dev onlyAuth. Reverts FUNDER_LOCKED / ZERO_ADDRESS / NOT_CONTRACT / FUNDER_TOKEN_MISMATCH /
    ///      FUNDER_NOT_LINKED.
    function setFunder(address funderAddr) external onlyAuth {
        _setFunder(funderAddr);
    }

    /// @notice Fix the funder and liquidity addresses for good. One-way. Call before taking real deposits. It
    ///         fixes only these two: the owner can still relink rewards here and the gateway and rewards on the
    ///         funder, which control the funder's USDT. Owner-only.
    /// @dev Reverts LIQUIDITY_NOT_LOCKED unless the liquidity contract is set and has been locked first.
    function lockFunder() external onlyOwner {
        require(liquidity != address(0) && IZyqorixLiquidity(liquidity).liquidityLocked(), "LIQUIDITY_NOT_LOCKED");
        funderLocked = true;
        emit FunderLocked();
    }

    /// @notice Set the rewards contract. Owner-only; can be changed again later (relink the funder's `setRewards`
    ///         to the same address). It decides who can draw on the funder. Relinking moves no member ledger.
    /// @param rewardsAddr The rewards contract.
    /// @dev Reverts ZERO_ADDRESS / SAME_REWARDS / NOT_CONTRACT / REWARDS_NOT_LINKED (its `gateway()` must be this
    ///      contract, or every credit and debit would revert), and reverts if it has no `walletBalance`.
    function setRewards(address rewardsAddr) external onlyOwner {
        require(rewardsAddr != address(0), "ZERO_ADDRESS");
        require(rewardsAddr != address(rewards), "SAME_REWARDS");
        require(rewardsAddr.code.length > 0, "NOT_CONTRACT");
        require(IZyqorixRewards(rewardsAddr).gateway() == address(this), "REWARDS_NOT_LINKED");
        IZyqorixRewards(rewardsAddr).walletBalance(address(this));
        rewards = IZyqorixRewards(rewardsAddr);
        emit RewardsSet(rewardsAddr);
    }

    /// @notice Change the contract that swaps withdrawal fees. Pass zero to send fees back to the funder.
    /// @param liquidityAddr The liquidity contract; it must swap from `token`.
    /// @dev onlyAuth. Reverts FUNDER_LOCKED / NOT_CONTRACT / LIQUIDITY_TOKEN_MISMATCH.
    function setLiquidity(address liquidityAddr) external onlyAuth {
        require(!funderLocked, "FUNDER_LOCKED");
        if (liquidityAddr != address(0)) {
            require(liquidityAddr.code.length > 0, "NOT_CONTRACT");
            require(IZyqorixLiquidity(liquidityAddr).USDT() == token, "LIQUIDITY_TOKEN_MISMATCH");
        }
        liquidity = liquidityAddr;
        emit LiquiditySet(liquidityAddr);
    }

    /// @notice Set the smallest amount a member can `deposit`.
    /// @param amount The new minimum (18-dp). 0 removes it.
    /// @dev onlyAuth.
    function setMinDeposit(uint256 amount) external onlyAuth {
        minDeposit = amount;
        emit MinDepositSet(amount);
    }

    /// @notice Set the withdrawal fee in basis points (e.g. 1000 = 10%).
    /// @param feeBps The new fee, at most MAX_WITHDRAWAL_FEE.
    /// @dev onlyAuth. Reverts FEE_TOO_HIGH.
    function setWithdrawalFee(uint256 feeBps) external onlyAuth {
        require(feeBps <= MAX_WITHDRAWAL_FEE, "FEE_TOO_HIGH");
        withdrawal_fee = feeBps;
        emit WithdrawalFeeSet(feeBps);
    }

    /// @notice Set the slippage tolerance for the fee swap, in basis points.
    /// @param slippageBps The new tolerance, at most 5000 (the liquidity contract's limit).
    /// @dev onlyAuth. Reverts SLIPPAGE_TOO_HIGH.
    function setLiquiditySlippage(uint24 slippageBps) external onlyAuth {
        // The liquidity contract's minimum out ignores the pool fee (1% on the ZQR pool), so anything below it
        // would make every fee swap fail and silently stop the burn.
        require(slippageBps >= 100, "SLIPPAGE_TOO_LOW");
        require(slippageBps <= 5_000, "SLIPPAGE_TOO_HIGH");
        liquiditySlippageBps = slippageBps;
        emit LiquiditySlippageSet(slippageBps);
    }

    /// @notice Pause or unpause deposits and withdrawals.
    /// @param _paused True to pause.
    /// @dev onlyAuth.
    function setPaused(bool _paused) external onlyAuth {
        paused = _paused;
        emit PausedSet(_paused);
    }

    /// @notice Set the per-account withdrawal cooldown in seconds (0 disables).
    /// @param secondsBetween The new cooldown.
    /// @dev onlyAuth.
    function setWithdrawalCooldown(uint256 secondsBetween) external onlyAuth {
        withdrawal_cooldown = secondsBetween;
        emit WithdrawalCooldownSet(secondsBetween);
    }

    /// @notice Set the withdrawal amount rule: from `min` to `max`, in multiples of `step`. For example 20, 200, 20
    ///         allows 20, 40, ... 200.
    /// @param min The smallest withdrawal; a multiple of `step`.
    /// @param max The largest withdrawal; a multiple of `step`, at least `min`.
    /// @param step The multiple every withdrawal must be; above zero.
    /// @dev onlyAuth. Reverts BAD_LIMITS.
    function setWithdrawalLimits(uint256 min, uint256 max, uint256 step) external onlyAuth {
        require(step > 0 && min > 0 && min <= max && min % step == 0 && max % step == 0, "BAD_LIMITS");
        withdrawalMin = min;
        withdrawalMax = max;
        withdrawalStep = step;
        emit WithdrawalLimitsSet(min, max, step);
    }

    /// @notice Forward any tokens sent here by mistake to the funder, restoring the zero balance.
    /// @param tokenAddr The token to forward.
    /// @dev onlyAuth. Reverts NOTHING.
    function sweep(address tokenAddr) external onlyAuth nonReentrant {
        uint256 bal = IERC20(tokenAddr).balanceOf(address(this));
        require(bal > 0, "NOTHING");
        _safeTransfer(tokenAddr, address(funder), bal);
        emit Swept(tokenAddr, bal);
    }

    /* =============================== SELF ============================== */
    /// @notice Swap `fee` to the token and burn what comes back. Only callable by this contract, so that
    ///         `_withdraw` can try it as one step: if any part fails, all of it rolls back.
    /// @param fee The fee to swap, already held here.
    /// @return burned The tokens burned.
    /// @dev Reverts ONLY_SELF / NO_POSITION / NOTHING_BOUGHT. With TOKENID 0 the swap and burn are skipped and
    ///      the fee goes back to the funder.
    function swapAndBurnFee(uint256 fee) external returns (uint256 burned) {
        require(msg.sender == address(this), "ONLY_SELF");
        IZyqorixLiquidity lp = IZyqorixLiquidity(liquidity);
        require(lp.TOKENID() != 0, "NO_POSITION");
        address swapped = lp.TOKEN();

        _safeApprove(token, address(lp), fee);
        burned = lp.swapUSDTToToken(fee, liquiditySlippageBps, address(this), block.timestamp);
        _safeApprove(token, address(lp), 0);
        require(burned > 0, "NOTHING_BOUGHT");

        try IERC20Burnable(swapped).burn(burned) {} catch {
            _safeTransfer(swapped, BURN_ADDRESS, burned);
        }
    }

    /* ============================== VIEWS ============================== */
    /// @notice The tokens the current funder holds.
    /// @return The funder's token balance.
    function funderBalance() public view returns (uint256) {
        return IERC20(token).balanceOf(address(funder));
    }

    /// @notice Whether `amount` is an allowed withdrawal: from `withdrawalMin` to `withdrawalMax`, in multiples of
    ///         `withdrawalStep`.
    /// @param amount The gross amount to check.
    /// @return True if allowed.
    function isAllowedWithdrawal(uint256 amount) public view returns (bool) {
        return amount >= withdrawalMin && amount <= withdrawalMax && amount % withdrawalStep == 0;
    }

    /* ---------------------------- Internals ---------------------------- */
    /// @dev Point at `funderAddr` after checking it can't stop withdrawals.
    function _setFunder(address funderAddr) internal {
        require(!funderLocked, "FUNDER_LOCKED");
        require(funderAddr != address(0), "ZERO_ADDRESS");
        require(funderAddr.code.length > 0, "NOT_CONTRACT");
        require(IZyqorixFunder(funderAddr).token() == token, "FUNDER_TOKEN_MISMATCH");
        require(IZyqorixFunder(funderAddr).gateway() == address(this), "FUNDER_NOT_LINKED");
        funder = IZyqorixFunder(funderAddr);
        emit FunderSet(funderAddr);
    }

    /// @dev Record what the funder received in `user`'s wallet balance and restart the withdrawal cooldown.
    function _creditDeposit(address user, uint256 received) internal {
        rewards.creditDeposit(user, received);
        coolDown[user] = block.timestamp + withdrawal_cooldown;
        emit Deposited(user, address(funder), received);
    }

    /// @dev transferFrom that works with tokens returning bool AND non-returning tokens.
    function _safeTransferFrom(address tokenAddress, address from, address to, uint256 value) internal {
        (bool ok, bytes memory data) = tokenAddress.call(
            abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, value)
        );
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "TRANSFER_FROM_FAILED");
    }

    /// @dev Require the funder to hold `amount`, pulling the funding wallets first when it holds less. Runs after
    ///      the debit, which already pulls when reward credit exceeds the pool; this also covers a payout the
    ///      funder is short of because the trading share has left for good. A failed pull never blocks a payout
    ///      the funder can already cover. Reverts INSUFFICIENT_FUNDER.
    function _requireFunderCovers(uint256 amount) internal {
        if (funderBalance() < amount) {
            try funder.pullFunding() {} catch {}
        }
        require(funderBalance() >= amount, "INSUFFICIENT_FUNDER");
    }

    /// @dev Shared withdrawal path: run the checks and debit the wallet, take the gross amount from the funder,
    ///      pay `user`, then swap and burn the fee. A failed swap never blocks the withdrawal: the fee is
    ///      booked into the reward pool (`_returnFee`) and `Withdrawn` reports burned = 0.
    function _withdraw(address user, uint256 amount) internal {
        require(accounts.isUser(user), "NOT_REGISTERED");
        require(amount > 0, "ZERO_AMOUNT");
        require(address(rewards) != address(0), "REWARDS_NOT_SET");
        require(isAllowedWithdrawal(amount), "BAD_WITHDRAWAL_AMOUNT");
        require(rewards.walletBalance(user) >= amount, "INSUFFICIENT_WALLET");

        _checkCooldown(user);

        uint256 fee = (amount * withdrawal_fee) / BPS_DENOMINATOR;
        uint256 net = amount - fee;

        rewards.debitWallet(user, amount);
        _requireFunderCovers(amount);
        funder.pay(address(this), amount);
        _safeTransfer(token, user, net);

        uint256 burned;
        if (fee > 0) {
            if (liquidity != address(0)) {
                // Makes eth_estimateGas include the swap: a limit too low for it now reverts instead of
                // quietly skipping the burn.
                require(gasleft() >= FEE_SWAP_GAS, "LOW_GAS_FOR_BURN");
                try this.swapAndBurnFee{gas: gasleft() - FEE_RETURN_GAS}(fee) returns (uint256 out) {
                    burned = out;
                } catch {}
            }
            if (burned == 0) _returnFee(fee);
        }
        emit Withdrawn(user, address(funder), amount, net, fee, burned);
    }

    /// @dev Put a fee that wasn't swapped and burned into the reward pool, through `funder.fundRewards`. Should
    ///      that fail, the fee still goes to the funder as plain USDT, so a withdrawal never reverts over its fee.
    function _returnFee(uint256 fee) internal {
        _safeApprove(token, address(funder), fee);
        try funder.fundRewards(fee) {} catch {
            _safeTransfer(token, address(funder), fee);
        }
        _safeApprove(token, address(funder), 0);
    }

    /// @dev Require the cooldown to have passed, then restart it.
    function _checkCooldown(address user) internal {
        if (withdrawal_cooldown > 0) {
            require(block.timestamp > coolDown[user], "COOLDOWN");
            coolDown[user] = block.timestamp + withdrawal_cooldown;
        }
    }

    /// @dev transfer that works with tokens returning bool AND non-returning tokens.
    function _safeTransfer(address tokenAddr, address to, uint256 value) internal {
        require(tokenAddr.code.length > 0, "NOT_CONTRACT");
        (bool ok, bytes memory data) = tokenAddr.call(abi.encodeWithSelector(IERC20.transfer.selector, to, value));
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "TRANSFER_FAILED");
    }

    /// @dev approve that works with tokens returning bool AND non-returning tokens.
    function _safeApprove(address tokenAddr, address spender, uint256 value) internal {
        require(tokenAddr.code.length > 0, "NOT_CONTRACT");
        (bool ok, bytes memory data) = tokenAddr.call(abi.encodeWithSelector(IERC20.approve.selector, spender, value));
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "APPROVE_FAILED");
    }
}
