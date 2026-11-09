// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/*
 * ZYQORIX — Funding Puller
 * Lets the client fund the reward pool by keeping USDT in up to MAX_WALLETS funding wallets of their own (for
 * example the addresses their exchange withdrawals land in). Each wallet approves this contract once; from then
 * on `pull` moves whatever USDT every wallet holds (up to its allowance) into the live funder through one
 * `funder.fundRewards`, so it is booked exactly like a manual funding: outstanding trading capital is repaid first
 * and the rest enters the reward pool. USDT sent to this contract directly is booked the same way on the next pull.
 *
 * `pull` is open to anyone, and rewards calls it on its own when a withdrawal or an activation needs more reward
 * pool than there is. The only place pulled USDT can go is `fundRewards`: this contract has no USDT withdrawal.
 * Revoking the approval (approve(this, 0)) stops it at once.
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
/*                              Wiring interfaces                             */
/* -------------------------------------------------------------------------- */
/// @title IZyqorixAccounts
/// @notice The authority view this contract reads from the ZYQORIX accounts contract.
interface IZyqorixAccounts {
    /// @notice The accounts contract owner — the single highest authority.
    function owner() external view returns (address);
}

/// @title IZyqorixGateway
/// @notice The gateway's live funder, followed on every pull so a funder migration needs no new puller.
interface IZyqorixGateway {
    function funder() external view returns (address);
}

/// @title IZyqorixFunder
/// @notice Books returned trading money: capital first, then the reward pool.
interface IZyqorixFunder {
    function token() external view returns (address);
    function fundRewards(uint256 amount) external;
}

/* ========================================================================== */
/*                            ZyqorixFundingPuller                            */
/* ========================================================================== */
/// @title ZyqorixFundingPuller
/// @author ZYQORIX
/// @notice Pulls the funding wallet's approved USDT into `funder.fundRewards`. Anyone can trigger it.
contract ZyqorixFundingPuller {
    /* ------------------------------- Wiring ---------------------------- */
    /// @notice The accounts contract — the source of the owner. Immutable.
    IZyqorixAccounts public immutable accounts;
    /// @notice The gateway, read for the live funder. Immutable.
    IZyqorixGateway public immutable gateway;
    /// @notice The most funding wallets at once. Bounds the gas a withdrawal spends pulling.
    uint256 public constant MAX_WALLETS = 5;
    /// @notice The wallets whose USDT funds the reward pool. Empty disables pulling.
    address[] private _wallets;
    /// @notice True for each current funding wallet.
    mapping(address => bool) public isFundingWallet;

    uint256 private _status = 1; // 1 = not entered, 2 = entered

    /* ------------------------------- Events ---------------------------- */
    /// @notice Emitted when a funding wallet is added.
    /// @param wallet The wallet.
    event FundingWalletAdded(address indexed wallet);
    /// @notice Emitted when a funding wallet is removed.
    /// @param wallet The wallet.
    event FundingWalletRemoved(address indexed wallet);
    /// @notice Emitted when USDT is pulled from the funding wallet and booked through `fundRewards`.
    /// @param wallet The funding wallet.
    /// @param funder The funder it was booked into.
    /// @param amount The amount pulled.
    event FundingPulled(address indexed wallet, address indexed funder, uint256 amount);
    /// @notice Emitted when a token other than the payment token is recovered.
    /// @param token The token.
    /// @param to The recipient.
    /// @param amount The amount sent.
    event TokenRecovered(address indexed token, address indexed to, uint256 amount);

    /* ------------------------------ Modifiers -------------------------- */
    /// @dev Restricts a function to the accounts OWNER. Reverts NOT_OWNER.
    modifier onlyOwner() {
        require(msg.sender == accounts.owner(), "NOT_OWNER");
        _;
    }

    /// @dev Prevents nested calls. Reverts REENTRANCY.
    modifier nonReentrant() {
        require(_status == 1, "REENTRANCY");
        _status = 2;
        _;
        _status = 1;
    }

    /* ----------------------------- Constructor ------------------------- */
    /// @notice Deploy the puller.
    /// @param accountsAddr The accounts contract.
    /// @param gatewayAddr The gateway whose funder receives the funding.
    /// @dev Reverts NOT_CONTRACT.
    constructor(address accountsAddr, address gatewayAddr) {
        require(accountsAddr.code.length > 0 && gatewayAddr.code.length > 0, "NOT_CONTRACT");
        accounts = IZyqorixAccounts(accountsAddr);
        gateway = IZyqorixGateway(gatewayAddr);
    }

    /* ------------------------------- Pull ------------------------------ */
    /// @notice Move every funding wallet's USDT, each up to its allowance to this contract, plus any USDT sent here
    ///         directly, into one `funder.fundRewards`. Anyone can call it; rewards calls it when the reward pool is
    ///         short. A wallet whose transfer fails is skipped, so it can't hold up the others.
    /// @return amount The total USDT booked (0 when nothing is pending).
    /// @dev Reverts the funder's REWARDS_NOT_SET / MIGRATED.
    function pull() external nonReentrant returns (uint256 amount) {
        IZyqorixFunder funder = IZyqorixFunder(gateway.funder());
        address token = funder.token();
        uint256 count = _wallets.length;
        for (uint256 i = 0; i < count; i++) {
            address wallet = _wallets[i];
            uint256 part = _pending(token, wallet);
            if (part == 0 || !_tryTransferFrom(token, wallet, address(this), part)) continue;
            emit FundingPulled(wallet, address(funder), part);
        }
        amount = IERC20(token).balanceOf(address(this)); // what was pulled, plus any USDT sent here directly
        if (amount == 0) return 0;

        _safeApprove(token, address(funder), amount);
        funder.fundRewards(amount);
        _safeApprove(token, address(funder), 0);
    }

    /* ------------------------------- Admin ----------------------------- */
    /// @notice Add a funding wallet. It must still approve this contract before anything is pulled from it.
    /// @param wallet The wallet.
    /// @dev Owner-only. Reverts ZERO_ADDRESS / ALREADY_ADDED / TOO_MANY_WALLETS.
    function addFundingWallet(address wallet) external onlyOwner {
        require(wallet != address(0), "ZERO_ADDRESS");
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

    /// @notice Recover a token sent here by mistake. The payment token can never leave this way (`pull` books it).
    /// @param tokenAddr The token to move.
    /// @param to The recipient.
    /// @param amount The amount to send.
    /// @dev Owner-only. Reverts PAYMENT_TOKEN_LOCKED / ZERO_ADDRESS.
    function recoverToken(address tokenAddr, address to, uint256 amount) external onlyOwner {
        require(tokenAddr != IZyqorixFunder(gateway.funder()).token(), "PAYMENT_TOKEN_LOCKED");
        require(to != address(0), "ZERO_ADDRESS");
        _safeTransfer(tokenAddr, to, amount);
        emit TokenRecovered(tokenAddr, to, amount);
    }

    /* ------------------------------- Views ----------------------------- */
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

    /// @notice What `pull` would move from one wallet: its USDT, capped by its allowance to this contract.
    /// @param wallet The wallet (counted whether or not it is a funding wallet).
    /// @return The amount.
    function pendingOf(address wallet) external view returns (uint256) {
        return _pending(IZyqorixFunder(gateway.funder()).token(), wallet);
    }

    /// @notice What `pull` would move now: every funding wallet's pending USDT plus any USDT held here.
    /// @return total The total (0 when nothing is waiting).
    function pending() external view returns (uint256 total) {
        address token = IZyqorixFunder(gateway.funder()).token();
        total = IERC20(token).balanceOf(address(this));
        uint256 count = _wallets.length;
        for (uint256 i = 0; i < count; i++) {
            total += _pending(token, _wallets[i]);
        }
    }

    function _pending(address token, address wallet) internal view returns (uint256) {
        uint256 balance = IERC20(token).balanceOf(wallet);
        uint256 allowed = IERC20(token).allowance(wallet, address(this));
        return balance < allowed ? balance : allowed;
    }

    /* ---------------------- Safe BEP20 helpers ------------------------- */
    /// @dev transferFrom that works with tokens returning bool AND non-returning tokens. Returns false instead of
    ///      reverting, so one failing wallet doesn't stop the pull.
    function _tryTransferFrom(address tokenAddr, address from, address to, uint256 value) internal returns (bool) {
        (bool ok, bytes memory data) =
            tokenAddr.call(abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, value));
        return ok && (data.length == 0 || (data.length >= 32 && abi.decode(data, (bool))));
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
