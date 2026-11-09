// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

/*
 * ZYQORIX — Vesting Module
 * Keeps the vesting record of every activation. Rewards creates a position worth the tier at the current
 * price, for example $100 at 0.001 USDT per ZQR is 100,000 ZQR. A position's amount is divided by its number
 * of months (60 by default). One month is 30 days (30 minutes on the local test chain), counted from the activation, and unclaimed months
 * accumulate. The operator funds it with a plain ZQR transfer to this address. A position can only be created against
 * ZQR that is here and not already reserved, so the contract never promises more than it holds.
 *
 * `emergencyWithdraw` moves everything, reserved ZQR included, to a replacement contract when the vesting
 * model changes. This contract then stops: claims and new positions revert, and its records stay readable
 * so the replacement can honor them.
 */

/* -------------------------------------------------------------------------- */
/*                        IERC20 (minimal BEP20 interface)                    */
/* -------------------------------------------------------------------------- */
/// @title IERC20
/// @notice The subset of the BEP20 / ERC20 interface this contract uses.
interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
}

/* -------------------------------------------------------------------------- */
/*                    IZyqorixAccounts (single source of truth)               */
/* -------------------------------------------------------------------------- */
/// @title IZyqorixAccounts
/// @notice The authority view this contract reads from the accounts contract.
interface IZyqorixAccounts {
    /// @notice True if `account` is the accounts owner or an explicit admin.
    function checkIsAdmin(address account) external view returns (bool);
    /// @notice The accounts contract owner.
    function owner() external view returns (address);
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
/*                               ZyqorixVesting                               */
/* ========================================================================== */
/// @title ZyqorixVesting
/// @author ZYQORIX
/// @notice Token vesting in 30-day months. Claims aren't blocked by membership, and they stop only if the
///         owner moves the funds to a replacement contract with `emergencyWithdraw`.
/// @dev Whatever creates positions (an admin or a hub contract) must be an accounts admin.
contract ZyqorixVesting is ReentrancyGuard {
    /* ------------------------------- Wiring ---------------------------- */
    /// @notice The accounts contract — the source of owner and admin authority. Immutable.
    IZyqorixAccounts public immutable accounts;
    /// @notice The vested token: ZQR at its BSC mainnet address. The anvil testnet has a mock etched there
    ///         (chain/script/deploy-zqr.js), the same way USDT is.
    address public constant token = 0x43ADE7aE5E14e6dadD0f6967a0aDEADe56095e70;

    /* ----------------------------- Positions --------------------------- */
    /// @notice One vesting record.
    struct Position {
        uint256 amount;       // ZQR granted
        uint256 monthlyClaim; // amount / months
        uint256 totalClaim;   // ZQR already claimed
        uint40 startTime;     // activation time; the first month matures 30 days later
        uint40 lastClaim;     // time of the latest claim, 0 until the first
        uint16 months;        // number of monthly claims
        bool expired;         // true once totalClaim reaches amount
    }

    /// @dev Positions per user.
    mapping(address => Position[]) private _positions;
    /// @notice ZQR owed across every position and not yet claimed.
    uint256 public totalReserved;
    /// @notice The replacement contract, set by `emergencyWithdraw`. Zero while this contract is live.
    address public migratedTo;
    /// @notice Number of months applied to new positions.
    uint256 public vestingMonths = 60;
    /// @notice Highest allowed number of months.
    uint256 public constant MAX_MONTHS = 120;
    /// @notice Seconds in a vesting month: 30 days, or 30 minutes on the local test chain.
    uint256 public immutable MONTH;

    /* ------------------------------- Events ---------------------------- */
    /// @notice Emitted when a position is created.
    /// @param user The member.
    /// @param index The position index.
    /// @param amount The ZQR granted.
    /// @param months The number of monthly claims.
    event PositionCreated(address indexed user, uint256 indexed index, uint256 amount, uint256 months);
    /// @notice Emitted when `user` claims.
    /// @param user The member.
    /// @param amount The ZQR sent.
    event Claimed(address indexed user, uint256 amount);
    /// @notice Emitted when the number of months for new positions is changed.
    /// @param months The new number of months.
    event VestingMonthsSet(uint256 months);
    /// @notice Emitted when the owner takes back unreserved ZQR.
    /// @param to The recipient.
    /// @param amount The ZQR sent.
    event UnreservedWithdrawn(address indexed to, uint256 amount);
    /// @notice Emitted when the owner moves all ZQR to a replacement contract.
    /// @param newContract The replacement contract.
    /// @param amount The ZQR sent.
    event EmergencyWithdrawn(address indexed newContract, uint256 amount);

    /* ----------------------------- Constructor ------------------------- */
    /// @notice Deploy the vesting contract.
    /// @param accountsAddr The deployed accounts contract.
    /// @param monthLength Seconds in a vesting month: 30 days, or 30 minutes on chain 31337 only.
    /// @dev Reverts ZERO_ADDRESS / NOT_CONTRACT (also when ZQR has no code here) / BAD_MONTH.
    constructor(address accountsAddr, uint256 monthLength) {
        require(accountsAddr != address(0), "ZERO_ADDRESS");
        require(accountsAddr.code.length > 0 && token.code.length > 0, "NOT_CONTRACT");
        require(monthLength == 30 days || (monthLength == 30 minutes && block.chainid == 31337), "BAD_MONTH");
        MONTH = monthLength;
        accounts = IZyqorixAccounts(accountsAddr);
    }

    /* ============================== ADMIN ============================== */
    /// @notice Grant `amount` of ZQR to `user`, vesting over `vestingMonths`.
    /// @param user The member.
    /// @param amount The ZQR to reserve; must not exceed `available()`.
    /// @return index The new position's index.
    /// @dev Accounts owner or admin. Reverts NOT_AUTH / MIGRATED / ZERO_USER / ZERO_AMOUNT / INSUFFICIENT_POOL.
    function createPosition(address user, uint256 amount) external returns (uint256 index) {
        require(accounts.checkIsAdmin(msg.sender), "NOT_AUTH");
        require(migratedTo == address(0), "MIGRATED");
        require(user != address(0), "ZERO_USER");
        require(amount > 0, "ZERO_AMOUNT");
        require(amount <= available(), "INSUFFICIENT_POOL");

        totalReserved += amount;
        index = _positions[user].length;
        _positions[user].push(Position({
            amount: amount,
            monthlyClaim: amount / vestingMonths,
            totalClaim: 0,
            startTime: uint40(block.timestamp),
            lastClaim: 0,
            months: uint16(vestingMonths),
            expired: false
        }));
        emit PositionCreated(user, index, amount, vestingMonths);
    }

    /// @notice Set the number of months for new positions. Existing positions keep theirs.
    /// @param months The new number of months (1 to MAX_MONTHS).
    /// @dev Accounts owner or admin. Reverts NOT_AUTH / BAD_MONTHS.
    function setVestingMonths(uint256 months) external {
        require(accounts.checkIsAdmin(msg.sender), "NOT_AUTH");
        require(months > 0 && months <= MAX_MONTHS, "BAD_MONTHS");
        vestingMonths = months;
        emit VestingMonthsSet(months);
    }

    /// @notice Take back ZQR that no position has reserved. Reserved ZQR can't be moved.
    /// @param to The recipient.
    /// @param amount The ZQR to send; must not exceed `available()`.
    /// @dev Accounts owner only. Reverts NOT_OWNER / ZERO_ADDRESS / INSUFFICIENT_POOL.
    function withdrawUnreserved(address to, uint256 amount) external nonReentrant {
        require(msg.sender == accounts.owner(), "NOT_OWNER");
        require(to != address(0), "ZERO_ADDRESS");
        require(amount <= available(), "INSUFFICIENT_POOL");
        _safeTransfer(to, amount);
        emit UnreservedWithdrawn(to, amount);
    }

    /// @notice Move all ZQR here, reserved included, to the contract replacing this one. Claims and new
    ///         positions stop here for good; the replacement must honor the records kept here. Calling it
    ///         again sends any ZQR that arrived later.
    /// @param newContract The replacement contract.
    /// @dev Accounts owner only. Reverts NOT_OWNER / NOT_CONTRACT / NOTHING_TO_WITHDRAW.
    function emergencyWithdraw(address newContract) external nonReentrant {
        require(msg.sender == accounts.owner(), "NOT_OWNER");
        require(newContract.code.length > 0, "NOT_CONTRACT");
        uint256 amount = IERC20(token).balanceOf(address(this));
        require(amount > 0, "NOTHING_TO_WITHDRAW");
        migratedTo = newContract;
        _safeTransfer(newContract, amount);
        emit EmergencyWithdrawn(newContract, amount);
    }

    /* ============================== CLAIM ============================== */
    /// @notice Claim every matured month across your positions, including any earlier months you skipped.
    /// @return amount The ZQR sent.
    /// @dev Reverts MIGRATED / NOTHING_TO_CLAIM.
    function claim() external nonReentrant returns (uint256 amount) {
        require(migratedTo == address(0), "MIGRATED");
        Position[] storage list = _positions[msg.sender];
        for (uint256 i = 0; i < list.length; i++) {
            Position storage p = list[i];
            if (p.expired) continue;
            uint256 due = _claimable(p);
            if (due > 0) {
                p.totalClaim += due;
                p.lastClaim = uint40(block.timestamp);
                if (p.totalClaim >= p.amount) p.expired = true;
                amount += due;
            }
        }
        require(amount > 0, "NOTHING_TO_CLAIM");
        totalReserved -= amount;
        _safeTransfer(msg.sender, amount);
        emit Claimed(msg.sender, amount);
    }

    /* ============================== VIEWS ============================== */
    /// @notice ZQR here that no position has reserved.
    /// @return The unreserved balance (0 if the balance is below the reserved total or the funds have moved).
    function available() public view returns (uint256) {
        if (migratedTo != address(0)) return 0;
        uint256 held = IERC20(token).balanceOf(address(this));
        return held > totalReserved ? held - totalReserved : 0;
    }

    /// @notice ZQR `user` can claim right now.
    /// @param user The member.
    /// @return amount The claimable ZQR (0 once the funds have moved to a replacement).
    function claimable(address user) external view returns (uint256 amount) {
        if (migratedTo != address(0)) return 0;
        Position[] storage list = _positions[user];
        for (uint256 i = 0; i < list.length; i++) amount += _claimable(list[i]);
    }

    /// @notice The number of positions `user` has.
    /// @param user The member.
    /// @return The position count.
    function positionCount(address user) external view returns (uint256) {
        return _positions[user].length;
    }

    /// @notice One of `user`'s positions.
    /// @param user The member.
    /// @param index The position index.
    /// @return The position.
    function getPosition(address user, uint256 index) external view returns (Position memory) {
        return _positions[user][index];
    }

    /* ---------------------------- Internals ---------------------------- */
    /// @dev Matured months minus what was already claimed. The last month releases any rounding dust.
    function _claimable(Position memory p) internal view returns (uint256) {
        uint256 matured = (block.timestamp - p.startTime) / MONTH;
        uint256 unlocked = matured >= p.months ? p.amount : p.monthlyClaim * matured;
        return unlocked - p.totalClaim;
    }

    /// @dev transfer of ZQR that works with tokens returning bool AND non-returning tokens.
    function _safeTransfer(address to, uint256 value) internal {
        (bool ok, bytes memory data) = token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, value));
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "TRANSFER_FAILED");
    }
}
