// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/*
 * ZYQORIX — Funder Module
 * The treasury. It holds members' wallet money, the 20% buffer and the trading profit. Trading capital is
 * tracked: money coming back from trading counts as profit only after all capital sent out has returned,
 * and only that profit can pay daily rewards. The owner can never take the payment token out.
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
    /// @notice Add `amount` of trading profit to the daily pool.
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
/// @notice Holds the ZYQORIX payment token. `pay` is gateway-only and the activation flows are rewards-only.
/// @dev The gateway and rewards addresses can each be set once, so a swapped contract can't reach this money.
contract ZyqorixFunder {
    /* ------------------------------- Wiring ---------------------------- */
    /// @notice The accounts contract — the source of the owner. Immutable.
    IZyqorixAccounts public immutable accounts;
    /// @notice The payment token this funder pays out (USDT on BSC). Immutable.
    address public immutable token;
    /// @notice The only address allowed to call `pay`. Set once.
    address public gateway;
    /// @notice The only address allowed to run the activation flows. Set once.
    address public rewards;
    /// @notice Where the activation's trading share goes. Owner-set.
    address public tradingWallet;

    /* --------------------------- Trading ledger ------------------------ */
    /// @notice Total USDT ever sent to the trading wallet.
    uint256 public tradingCapitalOut;
    /// @notice Total of that capital returned through `fundRewards`.
    uint256 public tradingCapitalReturned;
    /// @notice Returned capital here that can be sent back to trading with `redeployCapital`.
    uint256 public capitalHeld;
    /// @notice Trading profit here and not yet claimed. The only money daily rewards can use.
    uint256 public rewardPool;

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
    /// @notice Emitted when an activation's trading share goes out, or returned capital is sent back.
    /// @param wallet The trading wallet.
    /// @param amount The amount sent.
    event TradingCapitalSent(address indexed wallet, uint256 amount);
    /// @notice Emitted when `fundRewards` is called.
    /// @param from The sender.
    /// @param capitalReturned The part that repaid trading capital.
    /// @param profit The part that counted as profit and entered the reward pool.
    event TradingReturned(address indexed from, uint256 capitalReturned, uint256 profit);
    /// @notice Emitted when an activation's liquidity share is sent.
    /// @param liquidity The liquidity contract.
    /// @param amount The amount offered.
    /// @param routed True if the liquidity contract took it; false leaves it here.
    event LiquidityRouted(address indexed liquidity, uint256 amount, bool routed);
    /// @notice Emitted when this funder takes over another funder's ledger.
    /// @param capitalOut The trading capital out.
    /// @param capitalReturned The trading capital returned.
    /// @param held The returned capital held.
    /// @param pool The reward pool.
    event LedgerImported(uint256 capitalOut, uint256 capitalReturned, uint256 held, uint256 pool);
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

    /* ----------------------------- Constructor ------------------------- */
    /// @notice Deploy the funder. Call `setGateway` once the gateway exists.
    /// @param accountsAddr The deployed ZYQORIX accounts contract.
    /// @param tokenAddr The payment token.
    /// @dev Reverts ZERO_ADDRESS / NOT_CONTRACT.
    constructor(address accountsAddr, address tokenAddr) {
        require(accountsAddr != address(0) && tokenAddr != address(0), "ZERO_ADDRESS");
        require(accountsAddr.code.length > 0 && tokenAddr.code.length > 0, "NOT_CONTRACT");
        accounts = IZyqorixAccounts(accountsAddr);
        token = tokenAddr;
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

    /// @notice Take over the trading and reward ledger when this funder replaces another. Gateway-only, and only
    ///         on an empty ledger, so a migration can't add to or overwrite real numbers.
    /// @param capitalOut The old funder's `tradingCapitalOut`.
    /// @param capitalReturned The old funder's `tradingCapitalReturned`.
    /// @param held The old funder's `capitalHeld`.
    /// @param pool The old funder's `rewardPool`.
    /// @dev Reverts NOT_GATEWAY / LEDGER_NOT_EMPTY.
    function importLedger(uint256 capitalOut, uint256 capitalReturned, uint256 held, uint256 pool) external {
        require(msg.sender == gateway, "NOT_GATEWAY");
        require(tradingCapitalOut == 0 && rewardPool == 0, "LEDGER_NOT_EMPTY");
        tradingCapitalOut = capitalOut;
        tradingCapitalReturned = capitalReturned;
        capitalHeld = held;
        rewardPool = pool;
        emit LedgerImported(capitalOut, capitalReturned, held, pool);
    }

    /* ============================= REWARDS ============================= */
    /// @notice Send an activation's trading share to the trading wallet and record it as capital out.
    /// @param amount The amount to send.
    /// @dev Rewards-only. Reverts NOT_REWARDS / TRADING_WALLET_NOT_SET.
    function sendToTrading(uint256 amount) external {
        require(msg.sender == rewards, "NOT_REWARDS");
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

    /// @notice Take `amount` out of the reward pool ledger for a member's daily claim. The USDT stays here and
    ///         backs their wallet balance.
    /// @param amount The amount claimed.
    /// @dev Rewards-only. Reverts NOT_REWARDS / INSUFFICIENT_REWARD_POOL.
    function drawRewardPool(uint256 amount) external {
        require(msg.sender == rewards, "NOT_REWARDS");
        require(amount <= rewardPool, "INSUFFICIENT_REWARD_POOL");
        rewardPool -= amount;
    }

    /* ============================= TRADING ============================= */
    /// @notice Return money from trading. It repays outstanding capital first; only what is left is profit,
    ///         which enters the reward pool. A plain transfer to this address does not count. Approve first.
    /// @param amount The amount to pull from the caller.
    /// @dev Reverts REWARDS_NOT_SET / ZERO_AMOUNT.
    function fundRewards(uint256 amount) external {
        require(rewards != address(0), "REWARDS_NOT_SET");
        require(amount > 0, "ZERO_AMOUNT");
        uint256 balBefore = IERC20(token).balanceOf(address(this));
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.transferFrom.selector, msg.sender, address(this), amount)
        );
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "TRANSFER_FROM_FAILED");
        uint256 received = IERC20(token).balanceOf(address(this)) - balBefore;

        uint256 outstanding = tradingCapitalOut - tradingCapitalReturned;
        uint256 capital = received < outstanding ? received : outstanding;
        uint256 profit = received - capital;
        tradingCapitalReturned += capital;
        capitalHeld += capital;
        if (profit > 0) {
            rewardPool += profit;
            IZyqorixRewards(rewards).notifyProfit(profit);
        }
        emit TradingReturned(msg.sender, capital, profit);
    }

    /* ============================== OWNER ============================== */
    /// @notice Set the only address allowed to call `pay`. Owner-only, and only once.
    /// @param gatewayAddr The gateway contract.
    /// @dev Reverts ZERO_ADDRESS / NOT_CONTRACT / ALREADY_SET.
    function setGateway(address gatewayAddr) external onlyOwner {
        require(gatewayAddr != address(0), "ZERO_ADDRESS");
        require(gatewayAddr.code.length > 0, "NOT_CONTRACT");
        require(gateway == address(0), "ALREADY_SET");
        gateway = gatewayAddr;
        emit GatewaySet(gatewayAddr);
    }

    /// @notice Set the only address allowed to run the activation flows. Owner-only, and only once.
    /// @param rewardsAddr The rewards contract.
    /// @dev Reverts ZERO_ADDRESS / NOT_CONTRACT / ALREADY_SET.
    function setRewards(address rewardsAddr) external onlyOwner {
        require(rewardsAddr != address(0), "ZERO_ADDRESS");
        require(rewardsAddr.code.length > 0, "NOT_CONTRACT");
        require(rewards == address(0), "ALREADY_SET");
        rewards = rewardsAddr;
        emit RewardsSet(rewardsAddr);
    }

    /// @notice Set the trading wallet. Owner-only.
    /// @param wallet The new trading wallet.
    /// @dev Reverts ZERO_ADDRESS.
    function setTradingWallet(address wallet) external onlyOwner {
        require(wallet != address(0), "ZERO_ADDRESS");
        tradingWallet = wallet;
        emit TradingWalletSet(wallet);
    }

    /// @notice Send returned capital back to the trading wallet, so trading can keep running. Owner-only.
    /// @param amount The amount to send, at most `capitalHeld`.
    /// @dev Reverts TRADING_WALLET_NOT_SET / INSUFFICIENT_CAPITAL.
    function redeployCapital(uint256 amount) external onlyOwner {
        require(tradingWallet != address(0), "TRADING_WALLET_NOT_SET");
        require(amount <= capitalHeld, "INSUFFICIENT_CAPITAL");
        capitalHeld -= amount;
        tradingCapitalOut += amount;
        _safeTransfer(token, tradingWallet, amount);
        emit TradingCapitalSent(tradingWallet, amount);
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
