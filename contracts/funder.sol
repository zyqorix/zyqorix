// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

/*
 * ZYQORIX — Funder Module
 * The treasury. It holds members' wallet money, what activations leave in it and the trading profit. The trading
 * share of each activation is spent on trading and never comes back; `tradingCapitalOut` only counts it. Every USDT
 * returned through `fundRewards` or the funding wallets is trading profit and enters the reward pool, which alone
 * pays out daily and generation rewards. The owner can send any USDT held here, member deposits included, to the
 * trading wallet with `sendToTrading` (owner 2026-11-09, disclosed to members; not capped to the surplus, so an
 * oversized send leaves withdrawals failing until the treasury is refilled). The owner can also relink the gateway
 * and rewards addresses (setGateway, setRewards), and whatever they point at controls this USDT. The trading wallet can never be a funding wallet: returned trading capital would then book as profit,
 * and member deposits would pay daily rewards. Only profit may land in a funding wallet.
 *
 * Funding wallets: up to MAX_WALLETS client wallets (for example where exchange withdrawals land) approve this
 * funder once. `pullFunding` (anyone, and rewards on its own when the reward pool is short) moves each wallet's
 * USDT, up to its allowance, in here and books it exactly like `fundRewards`: all of it to the reward pool.
 * There is no funder migration: the address is permanent; the owner relinks gateway and rewards instead.
 */

/* -------------------------------------------------------------------------- */
/*                        IERC20 (minimal BEP20 interface)                    */
/* -------------------------------------------------------------------------- */
/// @title IERC20
/// @notice The subset of the BEP20 / ERC20 interface this contract uses.
interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function approve(address spender, uint256 value) external returns (bool);
}

/* -------------------------------------------------------------------------- */
/*                    IZyqorixAccounts (single source of truth)               */
/* -------------------------------------------------------------------------- */
/// @title IZyqorixAccounts
/// @notice The authority view this contract reads from the ZYQORIX accounts contract.
interface IZyqorixAccounts {
    /// @notice The accounts contract owner — the single highest authority.
    /// @return The current owner address.
    function owner() external view returns (address);
}

/* -------------------------------------------------------------------------- */
/*                              Rewards + Liquidity                           */
/* -------------------------------------------------------------------------- */
/// @title IZyqorixRewards
/// @notice Told when trading profit arrives.
interface IZyqorixRewards {
    /// @notice Told that `amount` of trading profit entered this funder's reward pool (event only).
    function notifyProfit(uint256 amount) external;
}

/// @title IZyqorixLiquidity
/// @notice Receives the activation's liquidity share. It pulls USDT from the caller.
interface IZyqorixLiquidity {
    /// @notice Pull `usdtAmount` and route it by the liquidity mode.
    /// @return A non-zero amount when handled, or 0 when nothing was pulled.
    function addLiquidityUSDT(uint256 usdtAmount, uint24 slippageBps, uint256 deadline) external returns (uint256);
}

/* ========================================================================== */
/*                               ZyqorixFunder                                */
/* ========================================================================== */
/// @title ZyqorixFunder
/// @author ZYQORIX
/// @notice Holds the ZYQORIX payment token. `pay` is gateway-only; `sendToTrading` is rewards or the accounts owner;
///         the other activation flows are rewards-only.
/// @dev The owner can relink the gateway and rewards addresses at any time (owner 2026-11-04), so a future
///      rewards or gateway change needs no new funder. Whoever holds the accounts owner key decides who can reach
///      this money.
contract ZyqorixFunder {
    /* ------------------------------- Wiring ---------------------------- */
    /// @notice The accounts contract — the source of the owner. Immutable.
    IZyqorixAccounts public immutable accounts;
    /// @notice The payment token this funder pays out: USDT at its BSC mainnet address. The anvil testnet
    ///         has a mock there (chain/script/deploy-usdt.js).
    address public constant token = 0x55d398326f99059fF775485246999027B3197955;
    /// @notice The only address allowed to call `pay`. Owner-set, relinkable.
    address public gateway;
    /// @notice The only address allowed to run the activation flows. Owner-set, relinkable.
    address public rewards;
    /// @notice Where the activation's trading share goes. Owner-set.
    address public tradingWallet;

    /* --------------------------- Trading ledger ------------------------ */
    /// @notice Total USDT ever sent to the trading wallet. A running total only: that capital is not repaid.
    uint256 public tradingCapitalOut;
    /// @notice Trading profit here and not yet claimed. The only money daily rewards can use.
    uint256 public rewardPool;

    /* --------------------------- Funding wallets ----------------------- */
    /// @notice The most funding wallets at once. Bounds the gas a withdrawal spends pulling.
    uint256 public constant MAX_WALLETS = 5;
    /// @notice The client wallets whose approved USDT funds the reward pool. Empty disables pulling.
    address[] private _wallets;
    /// @notice True for each current funding wallet.
    mapping(address => bool) public isFundingWallet;

    uint256 private _status = 1; // 1 = not entered, 2 = entered

    /* ------------------------------- Events ---------------------------- */
    /// @notice Emitted when the gateway pays `amount` to `to`.
    /// @param to The recipient.
    /// @param amount The amount sent.
    event Paid(address indexed to, uint256 amount);
    /// @notice Emitted when the gateway is set.
    /// @param gateway The gateway.
    event GatewaySet(address indexed gateway);
    /// @notice Emitted when the rewards contract is set.
    /// @param rewards The rewards contract.
    event RewardsSet(address indexed rewards);
    /// @notice Emitted when the trading wallet is changed.
    /// @param wallet The new trading wallet.
    event TradingWalletSet(address indexed wallet);
    /// @notice Emitted when USDT goes to the trading wallet: an activation's trading share or an owner send.
    /// @param wallet The trading wallet.
    /// @param amount The amount sent.
    event TradingCapitalSent(address indexed wallet, uint256 amount);
    /// @notice Emitted when trading profit enters the reward pool, through `fundRewards` or `pullFunding`.
    /// @param from The sender (this funder itself for `pullFunding`).
    /// @param amount The amount added to the reward pool.
    event RewardsFunded(address indexed from, uint256 amount);
    /// @notice Emitted when an activation's liquidity share is sent.
    /// @param liquidity The liquidity contract.
    /// @param amount The amount offered.
    /// @param routed True if the liquidity contract took it; false leaves it here.
    event LiquidityRouted(address indexed liquidity, uint256 amount, bool routed);
    /// @notice Emitted when a funding wallet is added.
    /// @param wallet The wallet.
    event FundingWalletAdded(address indexed wallet);
    /// @notice Emitted when a funding wallet is removed.
    /// @param wallet The wallet.
    event FundingWalletRemoved(address indexed wallet);
    /// @notice Emitted for each funding wallet `pullFunding` took USDT from.
    /// @param wallet The funding wallet.
    /// @param amount The amount pulled.
    event FundingPulled(address indexed wallet, uint256 amount);
    /// @notice Emitted when the owner moves tokens out of the funder.
    /// @param token The token moved.
    /// @param to The recipient.
    /// @param amount The amount sent.
    event FundsWithdrawn(address indexed token, address indexed to, uint256 amount);

    /* ------------------------------ Modifiers -------------------------- */
    /// @dev Restricts a function to the accounts OWNER. Reverts NOT_OWNER.
    modifier onlyOwner() {
        require(msg.sender == accounts.owner(), "NOT_OWNER");
        _;
    }

    /// @dev Prevents nested calls into the funding paths. Reverts REENTRANCY.
    modifier nonReentrant() {
        require(_status == 1, "REENTRANCY");
        _status = 2;
        _;
        _status = 1;
    }

    /* ----------------------------- Constructor ------------------------- */
    /// @notice Deploy the funder. Call `setGateway` when the gateway exists.
    /// @param accountsAddr The deployed ZYQORIX accounts contract.
    /// @dev Reverts ZERO_ADDRESS / NOT_CONTRACT (also when USDT has no code here).
    constructor(address accountsAddr) {
        require(accountsAddr != address(0), "ZERO_ADDRESS");
        require(accountsAddr.code.length > 0 && token.code.length > 0, "NOT_CONTRACT");
        accounts = IZyqorixAccounts(accountsAddr);
    }

    /* ============================ GATEWAY ============================= */
    /// @notice Pay `amount` of the token to `to`. Gateway-only.
    /// @param to The recipient (the gateway itself on a withdrawal).
    /// @param amount The amount to send.
    /// @dev Reverts NOT_GATEWAY.
    function pay(address to, uint256 amount) external {
        require(msg.sender == gateway, "NOT_GATEWAY");
        _safeTransfer(token, to, amount);
        emit Paid(to, amount);
    }

    /* ============================= REWARDS ============================= */
    /// @notice Send USDT to the trading wallet and record it as capital out: an activation's trading share (rewards)
    ///         or any amount the owner chooses (owner 2026-11-09).
    /// @param amount The amount to send.
    /// @dev Rewards or the accounts owner. Not capped to the surplus: an owner send can include member deposits.
    ///      Reverts NOT_REWARDS (any other caller) / TRADING_WALLET_NOT_SET.
    function sendToTrading(uint256 amount) external {
        require(msg.sender == rewards || msg.sender == accounts.owner(), "NOT_REWARDS");
        require(tradingWallet != address(0), "TRADING_WALLET_NOT_SET");
        tradingCapitalOut += amount;
        _safeTransfer(token, tradingWallet, amount);
        emit TradingCapitalSent(tradingWallet, amount);
    }

    /// @notice Send an activation's liquidity share to `liquidity`. A failure never blocks the activation:
    ///         the share simply stays here.
    /// @param liquidity The liquidity contract.
    /// @param amount The amount to offer.
    /// @param slippageBps Slippage tolerance.
    /// @dev Rewards-only. Reverts NOT_REWARDS.
    function sendToLiquidity(address liquidity, uint256 amount, uint24 slippageBps) external {
        require(msg.sender == rewards, "NOT_REWARDS");
        _safeApprove(token, liquidity, amount);
        bool routed;
        try IZyqorixLiquidity(liquidity).addLiquidityUSDT(amount, slippageBps, block.timestamp) returns (uint256 handled) {
            routed = handled > 0;
        } catch {}
        _safeApprove(token, liquidity, 0);
        emit LiquidityRouted(liquidity, amount, routed);
    }

    /// @notice Take `amount` out of the reward pool ledger when a member's daily or generation reward credit
    ///         leaves their wallet balance (a withdrawal or an activation). The USDT stays here until paid.
    /// @param amount The reward-credit part being spent.
    /// @dev Rewards-only. Reverts NOT_REWARDS / INSUFFICIENT_REWARD_POOL.
    function drawRewardPool(uint256 amount) external {
        require(msg.sender == rewards, "NOT_REWARDS");
        require(amount <= rewardPool, "INSUFFICIENT_REWARD_POOL");
        rewardPool -= amount;
    }

    /* ============================= TRADING ============================= */
    /// @notice Send trading profit into the reward pool. All of it counts: trading capital is not repaid. A plain
    ///         transfer to this address does not count. Approve first.
    /// @param amount The amount to pull from the caller.
    /// @dev Reverts REWARDS_NOT_SET / ZERO_AMOUNT.
    function fundRewards(uint256 amount) external nonReentrant {
        require(rewards != address(0), "REWARDS_NOT_SET");
        require(amount > 0, "ZERO_AMOUNT");
        uint256 balBefore = IERC20(token).balanceOf(address(this));
        require(_tryTransferFrom(msg.sender, amount), "TRANSFER_FROM_FAILED");
        _book(msg.sender, IERC20(token).balanceOf(address(this)) - balBefore);
    }

    /// @notice Pull every funding wallet's USDT, each up to its allowance to this funder, and book it like
    ///         `fundRewards`. Anyone can call it; rewards calls it when the reward pool is short. A wallet whose
    ///         transfer fails is skipped, so it can't hold up the others.
    /// @return amount The total booked (0 when nothing was pending).
    /// @dev Reverts REWARDS_NOT_SET.
    function pullFunding() external nonReentrant returns (uint256 amount) {
        require(rewards != address(0), "REWARDS_NOT_SET");
        uint256 balBefore = IERC20(token).balanceOf(address(this));
        uint256 count = _wallets.length;
        for (uint256 i = 0; i < count; i++) {
            address wallet = _wallets[i];
            uint256 part = _pending(wallet);
            if (part == 0 || !_tryTransferFrom(wallet, part)) continue;
            emit FundingPulled(wallet, part);
        }
        amount = IERC20(token).balanceOf(address(this)) - balBefore;
        if (amount > 0) _book(address(this), amount);
    }

    /* ============================== OWNER ============================== */
    /// @notice Set the only address allowed to call `pay`. Owner-only; can be changed again later.
    /// @param gatewayAddr The gateway contract.
    /// @dev Reverts ZERO_ADDRESS / NOT_CONTRACT / SAME_GATEWAY.
    function setGateway(address gatewayAddr) external onlyOwner {
        require(gatewayAddr != address(0), "ZERO_ADDRESS");
        require(gatewayAddr.code.length > 0, "NOT_CONTRACT");
        require(gatewayAddr != gateway, "SAME_GATEWAY");
        gateway = gatewayAddr;
        emit GatewaySet(gatewayAddr);
    }

    /// @notice Set the only address allowed to run the activation flows. Owner-only; can be changed again later.
    ///         Relinking moves no member ledger: balances stay in the old rewards contract.
    /// @param rewardsAddr The rewards contract.
    /// @dev Reverts ZERO_ADDRESS / NOT_CONTRACT / SAME_REWARDS.
    function setRewards(address rewardsAddr) external onlyOwner {
        require(rewardsAddr != address(0), "ZERO_ADDRESS");
        require(rewardsAddr.code.length > 0, "NOT_CONTRACT");
        require(rewardsAddr != rewards, "SAME_REWARDS");
        rewards = rewardsAddr;
        emit RewardsSet(rewardsAddr);
    }

    /// @notice Set the trading wallet. Owner-only.
    /// @param wallet The new trading disbursement contract.
    /// @dev Reverts ZERO_ADDRESS / FUNDING_WALLET.
    function setTradingWallet(address wallet) external onlyOwner {
        require(wallet != address(0), "ZERO_ADDRESS");
        require(!isFundingWallet[wallet], "FUNDING_WALLET");
        tradingWallet = wallet;
        emit TradingWalletSet(wallet);
    }

    /// @notice Add a funding wallet. It must still approve this funder before anything is pulled from it.
    /// @param wallet The wallet.
    /// @dev Owner-only. Reverts ZERO_ADDRESS / TRADING_WALLET / ALREADY_ADDED / TOO_MANY_WALLETS.
    function addFundingWallet(address wallet) external onlyOwner {
        require(wallet != address(0), "ZERO_ADDRESS");
        require(wallet != tradingWallet, "TRADING_WALLET");
        require(!isFundingWallet[wallet], "ALREADY_ADDED");
        require(_wallets.length < MAX_WALLETS, "TOO_MANY_WALLETS");
        _wallets.push(wallet);
        isFundingWallet[wallet] = true;
        emit FundingWalletAdded(wallet);
    }

    /// @notice Remove a funding wallet. Nothing more is pulled from it, whatever its allowance.
    /// @param wallet The wallet.
    /// @dev Owner-only. Reverts NOT_FUNDING_WALLET.
    function removeFundingWallet(address wallet) external onlyOwner {
        require(isFundingWallet[wallet], "NOT_FUNDING_WALLET");
        uint256 last = _wallets.length - 1;
        for (uint256 i = 0; i < last; i++) {
            if (_wallets[i] == wallet) {
                _wallets[i] = _wallets[last];
                break;
            }
        }
        _wallets.pop();
        isFundingWallet[wallet] = false;
        emit FundingWalletRemoved(wallet);
    }

    /// @notice Recover a token sent here by mistake. Owner-only. The payment token can never leave this way.
    /// @param tokenAddr The token to move.
    /// @param to The recipient.
    /// @param amount The amount to send.
    /// @dev Reverts PAYMENT_TOKEN_LOCKED / ZERO_ADDRESS.
    function withdrawFunds(address tokenAddr, address to, uint256 amount) external onlyOwner {
        require(tokenAddr != token, "PAYMENT_TOKEN_LOCKED");
        require(to != address(0), "ZERO_ADDRESS");
        _safeTransfer(tokenAddr, to, amount);
        emit FundsWithdrawn(tokenAddr, to, amount);
    }

    /* ============================== VIEWS ============================== */
    /// @notice The amount of the payment token this funder holds.
    /// @return The token balance.
    function available() external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    /// @notice The current funding wallets.
    /// @return The wallets, in pull order.
    function fundingWallets() external view returns (address[] memory) {
        return _wallets;
    }

    /// @notice How many funding wallets are set.
    /// @return The count.
    function walletCount() external view returns (uint256) {
        return _wallets.length;
    }

    /// @notice What `pullFunding` would take from one wallet: its USDT, capped by its allowance to this funder.
    /// @param wallet The wallet (counted whether or not it is a funding wallet).
    /// @return The amount.
    function pendingOf(address wallet) external view returns (uint256) {
        return _pending(wallet);
    }

    /// @notice What `pullFunding` would take now across every funding wallet.
    /// @return total The total (0 when no funding wallet is set).
    function pendingFunding() external view returns (uint256 total) {
        uint256 count = _wallets.length;
        for (uint256 i = 0; i < count; i++) {
            total += _pending(_wallets[i]);
        }
    }

    /* ---------------------------- Internals ---------------------------- */
    /// @dev Book `received` USDT of trading profit into the reward pool.
    function _book(address from, uint256 received) internal {
        rewardPool += received;
        IZyqorixRewards(rewards).notifyProfit(received);
        emit RewardsFunded(from, received);
    }

    function _pending(address wallet) internal view returns (uint256) {
        uint256 balance = IERC20(token).balanceOf(wallet);
        uint256 allowed = IERC20(token).allowance(wallet, address(this));
        return balance < allowed ? balance : allowed;
    }

    /// @dev Pull `value` USDT from `from`. Works with tokens returning bool AND non-returning tokens; returns false
    ///      instead of reverting.
    function _tryTransferFrom(address from, uint256 value) internal returns (bool) {
        (bool ok, bytes memory data) =
            token.call(abi.encodeWithSelector(IERC20.transferFrom.selector, from, address(this), value));
        return ok && (data.length == 0 || (data.length >= 32 && abi.decode(data, (bool))));
    }

    /* ---------------------- Safe BEP20 helpers ------------------------- */
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
