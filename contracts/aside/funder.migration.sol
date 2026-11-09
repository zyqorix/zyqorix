// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/*
 * ZYQORIX — Funder Module
 * The treasury. It holds members' wallet money, the 20% buffer and the trading profit. Trading capital is
 * tracked: money coming back from trading counts as profit only after all capital sent out has returned,
 * and only that profit enters the reward pool, which alone pays out daily and generation rewards. No function
 * lets the owner withdraw the payment token directly, but the owner can relink the gateway and rewards
 * addresses (setGateway, setRewards), and whatever they point at controls this USDT.
 *
 * Migration: the funder can move to an identical copy at a new address, in one transaction started by
 * `gateway.migrateFunder`. This funder checks the new one has exactly its own code, hands it the gateway,
 * rewards, trading wallet, ledger and every USDT, and then seals itself so nothing can use it again.
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
    /// @notice Told that `amount` of trading profit entered this funder's reward pool (event only).
    function notifyProfit(uint256 amount) external;
}

/// @title IZyqorixGatewayFunder
/// @notice The one gateway read a new funder needs during a migration.
interface IZyqorixGatewayFunder {
    /// @notice The gateway's live funder.
    function funder() external view returns (address);
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
    /// @notice Total USDT ever sent to the trading wallet.
    uint256 public tradingCapitalOut;
    /// @notice Total of that capital returned through `fundRewards`.
    uint256 public tradingCapitalReturned;
    /// @notice Returned capital here that can be sent back to trading with `redeployCapital`.
    uint256 public capitalHeld;
    /// @notice Trading profit here and not yet claimed. The only money daily rewards can use.
    uint256 public rewardPool;

    /* ----------------------------- Migration --------------------------- */
    /// @notice True once this funder has moved everything to `migratedTo`. A sealed funder can't pay, take
    ///         money or change its ledger again.
    bool public isSealed;
    /// @notice The funder that replaced this one. Zero while this funder is live.
    address public migratedTo;

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
    /// @notice Emitted when this funder takes over from `from`: its wiring and ledger.
    /// @param from The funder being replaced.
    /// @param capitalOut The trading capital out.
    /// @param capitalReturned The trading capital returned.
    /// @param held The returned capital held.
    /// @param pool The reward pool.
    event Adopted(address indexed from, uint256 capitalOut, uint256 capitalReturned, uint256 held, uint256 pool);
    /// @notice Emitted when this funder hands everything to `next` and seals itself.
    /// @param next The replacement funder.
    /// @param amount The USDT moved.
    event MigratedTo(address indexed next, uint256 amount);
    /// @notice Emitted when late USDT on a migrated funder is sent on to its replacement.
    /// @param next The replacement funder.
    /// @param amount The USDT forwarded.
    event Forwarded(address indexed next, uint256 amount);
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

    /// @dev Blocks every money and ledger path once this funder has migrated. Reverts MIGRATED.
    modifier notSealed() {
        require(!isSealed, "MIGRATED");
        _;
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
    function pay(address to, uint256 amount) external notSealed {
        require(msg.sender == gateway, "NOT_GATEWAY");
        _safeTransfer(token, to, amount);
        emit Paid(to, amount);
    }

    /// @notice Hand everything to `next`, an identical funder at a new address, and seal this one. Gateway-only:
    ///         `gateway.migrateFunder` calls it and then points itself at `next`, all in one transaction.
    /// @param next The replacement funder. It must have exactly this contract's code (so the same build and the
    ///        same accounts contract) and be fresh: no gateway, rewards or ledger yet.
    /// @return amount The USDT moved.
    /// @dev Seals first, then wires and funds `next`, then clears `gateway` so the gateway's `setFunder` can never
    ///      point back here (FUNDER_NOT_LINKED). Reverts NOT_GATEWAY / MIGRATED / SAME_FUNDER / CODE_MISMATCH, and
    ///      the `adopt` reverts.
    function migrateTo(address next) external notSealed returns (uint256 amount) {
        require(msg.sender == gateway, "NOT_GATEWAY");
        require(next != address(this), "SAME_FUNDER");
        require(next.code.length > 0 && next.codehash == address(this).codehash, "CODE_MISMATCH");
        isSealed = true;
        migratedTo = next;
        ZyqorixFunder(next).adopt(
            gateway, rewards, tradingWallet, tradingCapitalOut, tradingCapitalReturned, capitalHeld, rewardPool
        );
        amount = IERC20(token).balanceOf(address(this));
        if (amount > 0) _safeTransfer(token, next, amount);
        gateway = address(0);
        emit MigratedTo(next, amount);
    }

    /// @notice Send USDT that reached this funder after it migrated on to its replacement. Anyone can call it.
    ///         It lands there as surplus outside the ledger, like any plain transfer.
    /// @return amount The USDT forwarded.
    /// @dev Reverts NOT_MIGRATED while this funder is live.
    function forward() external returns (uint256 amount) {
        require(isSealed, "NOT_MIGRATED");
        amount = IERC20(token).balanceOf(address(this));
        if (amount > 0) _safeTransfer(token, migratedTo, amount);
        emit Forwarded(migratedTo, amount);
    }

    /// @notice Take over from the funder being replaced: its gateway, rewards, trading wallet and ledger. Called
    ///         once, by that funder's `migrateTo`, and only on a fresh funder.
    /// @dev The caller must have this contract's exact code and be the live funder of `gatewayAddr`, so only a
    ///      real migration can wire this funder. Reverts CODE_MISMATCH / NOT_LIVE_FUNDER / ALREADY_SET /
    ///      LEDGER_NOT_EMPTY.
    function adopt(
        address gatewayAddr,
        address rewardsAddr,
        address wallet,
        uint256 capitalOut,
        uint256 capitalReturned,
        uint256 held,
        uint256 pool
    ) external notSealed {
        require(msg.sender.codehash == address(this).codehash, "CODE_MISMATCH");
        require(
            ZyqorixFunder(msg.sender).gateway() == gatewayAddr && IZyqorixGatewayFunder(gatewayAddr).funder() == msg.sender,
            "NOT_LIVE_FUNDER"
        );
        require(gateway == address(0) && rewards == address(0), "ALREADY_SET");
        require(tradingCapitalOut == 0 && rewardPool == 0, "LEDGER_NOT_EMPTY");
        gateway = gatewayAddr;
        rewards = rewardsAddr;
        tradingWallet = wallet;
        tradingCapitalOut = capitalOut;
        tradingCapitalReturned = capitalReturned;
        capitalHeld = held;
        rewardPool = pool;
        emit GatewaySet(gatewayAddr);
        emit RewardsSet(rewardsAddr);
        emit TradingWalletSet(wallet);
        emit Adopted(msg.sender, capitalOut, capitalReturned, held, pool);
    }

    /* ============================= REWARDS ============================= */
    /// @notice Send an activation's trading share to the trading wallet and record it as capital out.
    /// @param amount The amount to send.
    /// @dev Rewards-only. Reverts NOT_REWARDS / TRADING_WALLET_NOT_SET.
    function sendToTrading(uint256 amount) external notSealed {
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
    function sendToLiquidity(address liquidity, uint256 amount, uint24 slippageBps) external notSealed {
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
    function drawRewardPool(uint256 amount) external notSealed {
        require(msg.sender == rewards, "NOT_REWARDS");
        require(amount <= rewardPool, "INSUFFICIENT_REWARD_POOL");
        rewardPool -= amount;
    }

    /* ============================= TRADING ============================= */
    /// @notice Return money from trading. It repays outstanding capital first; only what is left is profit,
    ///         which enters the reward pool. A plain transfer to this address does not count. Approve first.
    /// @param amount The amount to pull from the caller.
    /// @dev Reverts REWARDS_NOT_SET / ZERO_AMOUNT.
    function fundRewards(uint256 amount) external notSealed {
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
    /// @notice Set the only address allowed to call `pay`. Owner-only; can be changed again later.
    /// @param gatewayAddr The gateway contract.
    /// @dev Reverts ZERO_ADDRESS / NOT_CONTRACT / SAME_GATEWAY / MIGRATED.
    function setGateway(address gatewayAddr) external onlyOwner notSealed {
        require(gatewayAddr != address(0), "ZERO_ADDRESS");
        require(gatewayAddr.code.length > 0, "NOT_CONTRACT");
        require(gatewayAddr != gateway, "SAME_GATEWAY");
        gateway = gatewayAddr;
        emit GatewaySet(gatewayAddr);
    }

    /// @notice Set the only address allowed to run the activation flows. Owner-only; can be changed again later.
    ///         Relinking moves no member ledger: balances stay in the old rewards contract.
    /// @param rewardsAddr The rewards contract.
    /// @dev Reverts ZERO_ADDRESS / NOT_CONTRACT / SAME_REWARDS / MIGRATED.
    function setRewards(address rewardsAddr) external onlyOwner notSealed {
        require(rewardsAddr != address(0), "ZERO_ADDRESS");
        require(rewardsAddr.code.length > 0, "NOT_CONTRACT");
        require(rewardsAddr != rewards, "SAME_REWARDS");
        rewards = rewardsAddr;
        emit RewardsSet(rewardsAddr);
    }

    /// @notice Set the trading wallet. Owner-only.
    /// @param wallet The new trading disbursement contract.
    /// @dev Reverts ZERO_ADDRESS.
    function setTradingWallet(address wallet) external onlyOwner notSealed {
        require(wallet != address(0), "ZERO_ADDRESS");
        tradingWallet = wallet;
        emit TradingWalletSet(wallet);
    }

    /// @notice Send returned capital back to the trading wallet, so trading can keep running. Owner-only.
    /// @param amount The amount to send, at most `capitalHeld`.
    /// @dev Reverts TRADING_WALLET_NOT_SET / INSUFFICIENT_CAPITAL.
    function redeployCapital(uint256 amount) external onlyOwner notSealed {
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
