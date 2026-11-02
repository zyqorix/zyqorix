// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/*
 * ZYQORIX — Register Module
 * The public sign-up. A caller joins under a valid sponsor and pays the initial deposit through the
 * gateway in one transaction, so a failed deposit also undoes the registration. Holds no funds.
 */

/* -------------------------------------------------------------------------- */
/*                    IZyqorixAccounts (single source of truth)               */
/* -------------------------------------------------------------------------- */
/// @title IZyqorixAccounts
/// @notice The registry calls this contract needs. It must be an accounts admin to call `addUser`.
interface IZyqorixAccounts {
    /// @notice Add `user` under `sponsor`. Reverts SPONSOR_NOT_FOUND unless `sponsor` is registered.
    function addUser(address user, address sponsor) external;
    /// @notice True if `account` is the accounts owner or an explicit admin.
    function checkIsAdmin(address account) external view returns (bool);
    /// @notice The wallet at the top of the tree.
    function root() external view returns (address);
}

/* -------------------------------------------------------------------------- */
/*                               IZyqorixGateway                              */
/* -------------------------------------------------------------------------- */
/// @title IZyqorixGateway
/// @notice The deposit entry point. The member approves the gateway on the payment token.
interface IZyqorixGateway {
    /// @notice Pull `amount` from `user` into the funder and record it in `user`'s wallet balance.
    function depositFor(address user, address tokenAddress, uint256 amount) external;
    /// @notice The payment token.
    function token() external view returns (address);
    /// @notice The rewards contract.
    function rewards() external view returns (address);
}

/* -------------------------------------------------------------------------- */
/*                               IZyqorixRewards                              */
/* -------------------------------------------------------------------------- */
/// @title IZyqorixRewards
/// @notice Whether a sponsor is active.
interface IZyqorixRewards {
    /// @notice True while `user` has capping left.
    function isActive(address user) external view returns (bool);
}

/* ========================================================================== */
/*                               ZyqorixRegister                              */
/* ========================================================================== */
/// @title ZyqorixRegister
/// @author ZYQORIX
/// @notice Registers the caller under a valid sponsor and takes the initial deposit.
/// @dev Must be added with `accounts.addAdmin`, which lets it call `addUser` and `gateway.depositFor`.
contract ZyqorixRegister {
    /* ------------------------------- Wiring ---------------------------- */
    /// @notice The accounts contract. Immutable.
    IZyqorixAccounts public immutable accounts;
    /// @notice The gateway that takes the initial deposit. Immutable.
    IZyqorixGateway public immutable gateway;

    /* ------------------------------ Settings --------------------------- */
    /// @notice Deposit required to register, in the payment token (18-dp). 0 = no deposit required.
    uint256 public initialDeposit = 50 ether;

    /* ------------------------------- Events ---------------------------- */
    /// @notice Emitted when `user` registers under `sponsor`.
    /// @param user The new member.
    /// @param sponsor The member's sponsor.
    /// @param deposit The initial deposit paid (0 when none is required).
    event Registered(address indexed user, address indexed sponsor, uint256 deposit);
    /// @notice Emitted when the initial deposit is changed.
    /// @param amount The new amount.
    event InitialDepositSet(uint256 amount);

    /* ----------------------------- Constructor ------------------------- */
    /// @notice Deploy the register. Afterwards the owner calls `accounts.addAdmin(this)`.
    /// @param accountsAddr The deployed accounts contract.
    /// @param gatewayAddr The deployed gateway.
    /// @dev Reverts ZERO_ADDRESS / NOT_CONTRACT.
    constructor(address accountsAddr, address gatewayAddr) {
        require(accountsAddr != address(0) && gatewayAddr != address(0), "ZERO_ADDRESS");
        require(accountsAddr.code.length > 0 && gatewayAddr.code.length > 0, "NOT_CONTRACT");
        accounts = IZyqorixAccounts(accountsAddr);
        gateway = IZyqorixGateway(gatewayAddr);
    }

    /* ============================== REGISTER =========================== */
    /// @notice Join under `sponsor`. When `initialDeposit` is above zero, approve the gateway for that amount
    ///         first. Membership is EOA-only, as in COC; admins can add other wallets via accounts.addUser.
    /// @param sponsor An existing registered member.
    /// @dev Reverts CALLER_NOT_EOA / SPONSOR_NOT_ACTIVE. The sponsor must have capping left, except the root,
    ///      which starts the tree. `addUser` reverts SPONSOR_NOT_FOUND / ALREADY_REGISTERED / SELF_SPONSOR /
    ///      PAUSED. The deposit reverts without allowance or balance, or if the gateway is paused.
    function register(address sponsor) external {
        require(msg.sender == tx.origin, "CALLER_NOT_EOA");
        accounts.addUser(msg.sender, sponsor);
        require(
            sponsor == accounts.root() || IZyqorixRewards(gateway.rewards()).isActive(sponsor),
            "SPONSOR_NOT_ACTIVE"
        );
        uint256 deposit = initialDeposit;
        if (deposit > 0) gateway.depositFor(msg.sender, gateway.token(), deposit);
        emit Registered(msg.sender, sponsor, deposit);
    }

    /* ============================== ADMIN ============================== */
    /// @notice Set the deposit required to register. 0 removes the requirement.
    /// @param amount The new amount (18-dp).
    /// @dev Accounts owner or admin. Reverts NOT_AUTH.
    function setInitialDeposit(uint256 amount) external {
        require(accounts.checkIsAdmin(msg.sender), "NOT_AUTH");
        initialDeposit = amount;
        emit InitialDepositSet(amount);
    }
}
