// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

/*
 * ZYQORIX — Accounts Module
 * The account registry and central authority for ZYQORIX — the single source of truth for membership
 * (isUser) and admin/mod authority (checkIsAdmin), together with the referral-tree genealogy.
 * Self-contained (Ownable / AdminOwnable, Pausable, admin-gated registration, admin setters).
 */

 
 
/* -------------------------------------------------------------------------- */
/*                          Ownable (minimal, inlined)                        */
/* -------------------------------------------------------------------------- */
/// @title Ownable (two-step)
/// @author ZYQORIX
/// @notice Minimal single-owner access control (inlined, no external dependency) with a TWO-STEP
///         ownership transfer: the current owner nominates a pending owner, who must call
///         `acceptOwnership` to take control. This prevents losing ownership to a mistyped or
///         uncontrolled address — the change only lands once the nominee proves it can transact.
/// @dev The owner is stored privately and exposed via `owner()`; guards use the `onlyOwner` modifier.
abstract contract Ownable {
    /// @dev The current owner address.
    address private _owner;
    /// @dev The nominated next owner, pending acceptance. Zero when no transfer is in flight.
    address private _pendingOwner;

    /// @notice Emitted when ownership moves from `previousOwner` to `newOwner` (the initial set and each
    ///         completed transfer).
    /// @param previousOwner The prior owner (address(0) at construction).
    /// @param newOwner The new owner.
    event OwnershipTransferred(
        address indexed previousOwner,
        address indexed newOwner
    );
    /// @notice Emitted when the current owner nominates `newOwner` to take over (pending acceptance).
    /// @param previousOwner The current owner starting the transfer.
    /// @param newOwner The nominated pending owner.
    event OwnershipTransferStarted(
        address indexed previousOwner,
        address indexed newOwner
    );

    /// @notice Set the initial owner at deployment.
    /// @param initialOwner The address to grant ownership; must be non-zero.
    /// @dev Reverts with OWNABLE_ZERO_OWNER if `initialOwner` is the zero address.
    constructor(address initialOwner) {
        require(initialOwner != address(0), "OWNABLE_ZERO_OWNER");
        _owner = initialOwner;
        emit OwnershipTransferred(address(0), initialOwner);
    }

    /// @dev Restricts a function to the current owner; reverts NOT_OWNER otherwise.
    modifier onlyOwner() {
        require(msg.sender == _owner, "NOT_OWNER");
        _;
    }

    /// @notice The current owner of the contract.
    /// @return The owner address.
    function owner() public view returns (address) {
        return _owner;
    }

    /// @notice The pending owner nominated to take over, or address(0) if no transfer is in flight.
    /// @return The pending owner address.
    function pendingOwner() public view returns (address) {
        return _pendingOwner;
    }

    /// @notice Start a two-step ownership transfer by nominating `newOwner`. Owner-only. The nominee must
    ///         then call `acceptOwnership` to complete it. Ownership does NOT change here.
    /// @param newOwner The address to nominate as the next owner. Pass address(0) to cancel a pending
    ///        transfer.
    /// @dev Records the nominee and emits OwnershipTransferStarted. Overwrites any prior pending nominee.
    function transferOwnership(address newOwner) external onlyOwner {
        _pendingOwner = newOwner;
        emit OwnershipTransferStarted(_owner, newOwner);
    }

    /// @notice Complete a two-step ownership transfer. Callable only by the current pending owner.
    /// @dev Reverts NOT_PENDING_OWNER unless the caller is the nominee; clears the pending slot and emits
    ///      OwnershipTransferred.
    function acceptOwnership() external {
        require(msg.sender == _pendingOwner, "NOT_PENDING_OWNER");
        emit OwnershipTransferred(_owner, _pendingOwner);
        _owner = _pendingOwner;
        _pendingOwner = address(0);
    }
}

/* -------------------------------------------------------------------------- */
/*                               AdminOwnable                                 */
/* -------------------------------------------------------------------------- */
/// @title AdminOwnable
/// @author ZYQORIX
/// @notice Adds a set of admin addresses on top of `Ownable`. The owner is always an implicit admin.
/// @dev Admin membership gates operational functions via `onlyAdmin`; owner-only functions manage the set.
abstract contract AdminOwnable is Ownable {
    /// @notice Whether an address is an admin (the owner is always treated as an admin regardless).
    mapping(address => bool) public isAdmin;

    /// @notice Emitted when `admin` is granted admin rights.
    /// @param admin The newly added admin address.
    event AdminAdded(address indexed admin);
    /// @notice Emitted when `admin` has its admin rights revoked.
    /// @param admin The removed admin address.
    event AdminRemoved(address indexed admin);

    /// @dev Restricts a function to the owner or any admin; reverts NOT_AUTHORIZED_ADMIN otherwise.
    modifier onlyAdmin() {
        require(
            msg.sender == owner() || isAdmin[msg.sender],
            "NOT_AUTHORIZED_ADMIN"
        );
        _;
    }

    /// @notice Grant admin rights to `adminAddress`. Owner-only.
    /// @param adminAddress Address to promote; must be non-zero and not already an admin.
    /// @dev Reverts ZERO_ADDRESS / ALREADY_ADMIN; emits AdminAdded.
    function addAdmin(address adminAddress) external onlyOwner {
        require(adminAddress != address(0), "ZERO_ADDRESS");
        require(!isAdmin[adminAddress], "ALREADY_ADMIN");
        isAdmin[adminAddress] = true;
        emit AdminAdded(adminAddress);
    }

    /// @notice Revoke admin rights from `adminAddress`. Owner-only. Virtual so a derived contract can
    ///         protect a structural root admin if it grants one.
    /// @param adminAddress Address to demote; must be non-zero and currently an admin.
    /// @dev Reverts ZERO_ADDRESS / NOT_ADMIN; emits AdminRemoved.
    function removeAdmin(address adminAddress) external virtual onlyOwner {
        require(adminAddress != address(0), "ZERO_ADDRESS");
        require(isAdmin[adminAddress], "NOT_ADMIN");
        isAdmin[adminAddress] = false;
        emit AdminRemoved(adminAddress);
    }

    /// @notice Whether `addr` has admin authority (owner or explicit admin).
    /// @param addr Address to check.
    /// @return True if `addr` is the owner or an admin.
    /// @dev public so derived contracts (and their modifiers) can reuse it internally.
    function checkIsAdmin(address addr) public view returns (bool) {
        return addr == owner() || isAdmin[addr];
    }
}

/* ========================================================================== */
/*                                ZyqorixAccounts                                */
/* ========================================================================== */
/// @title ZyqorixAccounts
/// @author ZYQORIX
/// @notice The ZYQORIX account registry and central authority — the single source of truth for the whole
///         system. It holds the referral-tree genealogy (members register under a sponsor, forming one
///         acyclic tree rooted at the company anchor; admins can re-parent for migration) together with
///         membership (isUser) and admin/mod authority (checkIsAdmin). Other contracts — e.g. the
///         assets vault — read their access decisions from here.
/// @dev Self-contained (inlined Ownable / AdminOwnable) with a hand-rolled pause.
///      Registration is onlyAuth-gated (owner or an admin); no funds move here.
contract ZyqorixAccounts is AdminOwnable {
    /* --------------------------- Immutables ---------------------------- */
 
    /* ---------------------------- Genealogy ---------------------------- */
    /// @notice A member's position in the referral tree — their sponsor and their direct referrals.
    /// @dev `referral` is set on register; `children` lists direct referrals.
    struct Affiliate {
        address referral; // referral-tree sponsor (set on register)
        address[] children; // direct referrals in the referral tree
    }

    /// @dev Per-member genealogy record, keyed by member address.
    mapping(address => Affiliate) private _affiliate;
    /// @dev parent => child => (index in parent.children)+1; 0 = absent. Enables O(1) child removal.
    // parent => child => (index in parent.children) + 1; 0 = absent. Enables O(1) child removal.
    mapping(address => mapping(address => uint256)) private _childIndexPlus1;
    /// @notice The company anchor at the top of the referral tree (the permanent structural root).
    address public root; // company anchor / structural root
    /// @notice Total registered members, including root.
    uint256 public totalUsers;

    /// @notice Whether an address is registered into the referral tree.
    mapping(address => bool) public isUser; // registered into the referral tree

    /// @notice When each member registered (unix seconds). Rewards uses it for the tier day counters.
    mapping(address => uint256) public registeredAt;

    /// @notice Direct-referral count per member (kept in sync by _addChild / _removeChild).
    mapping(address => uint256) public totalDirects;

    /* ------------------------------ Pause ------------------------------ */
    /// @notice When true, addUser is blocked. Toggle via setPaused.
    bool public paused;

    /* ------------------------------ Events ----------------------------- */
    /// @notice Emitted when `user` registers into the tree under `sponsor`.
    /// @param user The wallet that was registered into the tree.
    /// @param sponsor The existing member the user was placed under.
    event Registered(address indexed user, address indexed sponsor);
    /// @notice Emitted when an admin re-parents `user` to `newParent`.
    /// @param user The member that was re-parented.
    /// @param newParent The member's new referral sponsor.
    event AffiliateParentUpdated(address indexed user, address indexed newParent);
    /// @notice Emitted when an admin removes `user`; their direct children were migrated to `migratedTo`.
    /// @param user The member that was removed (isUser set false, referral cleared to address(0)).
    /// @param migratedTo The removed member's former sponsor, which adopted all of their direct children.
    event UserRemoved(address indexed user, address indexed migratedTo);
    /// @notice Emitted when the pause flag is set to `paused`.
    /// @param paused The new pause state (true = paused).
    event PausedSet(bool paused);

    /* ---------------------------- Modifiers ---------------------------- */
    /// @dev Blocks the guarded function while the contract is paused; reverts PAUSED.
    modifier whenNotPaused() {
        require(!paused, "PAUSED");
        _;
    }

    /// @dev Restricts a function to an authorized caller — the owner or any admin (checkIsAdmin). The
    ///      membership hub is registered via addAdmin, so it passes here; there is no separate mainHub.
    modifier onlyAuth() {
        require(checkIsAdmin(msg.sender), "NOT_AUTH");
        _;
    }

    /* --------------------------- Constructor --------------------------- */
    /// @notice Deploy the accounts contract: sets the deployer as owner and seeds it as the `root` anchor
    ///         at the top of the referral tree.
    /// @dev Takes no arguments.
    ///
    ///      ROOT IS NOT GRANTED ADMIN. `root` is a STRUCTURAL role only — the anchor at the top of the
    ///      tree — and it has no setter, so it is permanent. Granting it admin too would make
    ///      the deployer EOA an irrevocable admin: `removeAdmin` could never demote it and
    ///      `transferOwnership` would not touch it. The deployer still has full admin access here via
    ///      `owner()` (see the onlyAdmin modifier), and that access moves cleanly with transferOwnership.
    constructor() Ownable(msg.sender) {
        root = msg.sender;
        isUser[root] = true;
        registeredAt[root] = block.timestamp;
        totalUsers = 1;
        emit Registered(root, address(0)); // announce root (no sponsor) so indexers see the tree anchor
    }

    /* ==================================================================== */
    /*                            USER — JOIN / PAY                          */
    /* ==================================================================== */

    /// @notice Add `user` into the referral tree under `sponsor`. Called by an authorized caller — the
    ///         owner or an admin (e.g. the membership hub, registered via addAdmin) — which supplies both
    ///         the user's wallet and the sponsor's wallet.
    /// @param user The wallet to register; must be non-zero and not already registered.
    /// @param sponsor An existing registered member to sponsor `user`; cannot be `user`.
    /// @dev onlyAuth + whenNotPaused. Reverts ZERO_USER / ALREADY_REGISTERED / SPONSOR_NOT_FOUND / SELF_SPONSOR.
    function addUser(address user, address sponsor) external onlyAuth whenNotPaused {
        require(user != address(0), "ZERO_USER");
        require(!isUser[user], "ALREADY_REGISTERED");
        require(isUser[sponsor], "SPONSOR_NOT_FOUND");
        require(sponsor != user, "SELF_SPONSOR");

        isUser[user] = true;
        registeredAt[user] = block.timestamp;
        _affiliate[user].referral = sponsor;
        _addChild(sponsor, user);
        totalUsers += 1;

        emit Registered(user, sponsor);
    }

    /* ==================================================================== */
    /*                               VIEWS                                  */
    /* ==================================================================== */
 

    /// @notice A member's sponsor and direct-referral count.
    /// @param user The member to query.
    /// @return referral The member's referral-tree sponsor.
    /// @return directCount The number of direct referrals (children) the member has.
    function getAffiliate(
        address user
    ) external view returns (address referral, uint256 directCount) {
        Affiliate storage a = _affiliate[user];
        return (a.referral, a.children.length);
    }

    /// @notice Paginated list of a member's direct referrals (children in the referral tree).
    /// @param user The member whose children to list.
    /// @param offset Starting index into the children array.
    /// @param limit Maximum number of entries to return.
    /// @return result The slice of child addresses (empty if offset is past the end).
    /// @return total The total number of children.
    function getChildren(
        address user,
        uint256 offset,
        uint256 limit
    ) external view returns (address[] memory result, uint256 total) {
        address[] storage ch = _affiliate[user].children;
        total = ch.length;
        if (offset >= total) return (new address[](0), total);
        uint256 remaining = total - offset;                 // safe: offset < total (early return above)
        uint256 n = limit < remaining ? limit : remaining;  // clamp without offset+limit → cannot overflow
        result = new address[](n);
        for (uint256 i = 0; i < n; i++) result[i] = ch[offset + i];
    }

    /// @notice Aggregated per-member snapshot returned by getUser for frontends.
    struct UserView {
        bool registered;
        address sponsor;
        uint256 directCount;
    }

    /// @notice One-call dashboard snapshot for a frontend.
    /// @param user The member to summarize.
    /// @return v A UserView with the registration flag, sponsor, and direct-referral count.
    function getUser(address user) external view returns (UserView memory v) {
        Affiliate storage a = _affiliate[user];
        v.registered = isUser[user];
        v.sponsor = a.referral;
        v.directCount = a.children.length;
    }
 

    /* ==================================================================== */
    /*                          ADMIN — GENEALOGY                           */
    /* ==================================================================== */

    /// @notice Correct a user's referral sponsor (migration). Guards against cycles. Root can't be re-parented.
    /// @param user The member to re-parent; must be registered and not root.
    /// @param newParent The member's new referral sponsor; must be registered, not `user`, and not the current parent.
    /// @dev onlyAdmin. Walks newParent to root to reject cycles (CIRCULAR_PARENT), then moves the child link.
    ///      Reverts USER_NOT_FOUND / CANNOT_REPARENT_ROOT / NEW_PARENT_NOT_FOUND / SELF_PARENT / ALREADY_SAME_PARENT.
    function updateAffiliateParent(
        address user,
        address newParent
    ) external onlyAdmin {
        require(isUser[user], "USER_NOT_FOUND");
        require(user != root, "CANNOT_REPARENT_ROOT");
        require(isUser[newParent], "NEW_PARENT_NOT_FOUND");
        require(newParent != user, "SELF_PARENT");
        require(newParent != _affiliate[user].referral, "ALREADY_SAME_PARENT");

        // Cycle check: user must not be an ancestor of newParent. The referral tree is acyclic (register adds
        // leaves; this guard blocks cycles), so the walk-to-root always terminates.
        address cursor = newParent;
        while (cursor != address(0)) {
            if (cursor == user) revert("CIRCULAR_PARENT");
            cursor = _affiliate[cursor].referral;
        }

        address oldParent = _affiliate[user].referral;
        if (oldParent != address(0)) _removeChild(oldParent, user);
        _affiliate[user].referral = newParent;
        _addChild(newParent, user);
        emit AffiliateParentUpdated(user, newParent);
    }

    /// @notice Remove `user` from the tree: migrate ALL of their direct children up to the user's own
    ///         sponsor, detach the user (referral → address(0)), and set isUser false. Root cannot be removed.
    /// @param user The member to remove; must be registered and not root.
    /// @dev onlyAdmin. The user's direct children (and their subtrees) are re-parented to the user's former
    ///      sponsor — each child keeps its own downline, only its parent pointer moves up one level, so the
    ///      tree stays acyclic (children were descendants of the sponsor already). Reverts USER_NOT_FOUND /
    ///      CANNOT_REMOVE_ROOT / NO_PARENT.
    ///
    ///      GAS: loops over the user's DIRECT children (O(directs)). Removing a member with a very large
    ///      direct count can exceed the block gas limit — reduce their directs first if this is a risk.
    function removeUser(address user) external onlyAdmin {
        require(isUser[user], "USER_NOT_FOUND");
        require(user != root, "CANNOT_REMOVE_ROOT");

        address parent = _affiliate[user].referral; // the user's sponsor — adopts the children
        require(parent != address(0), "NO_PARENT");

        // Migrate every direct child of `user` up to `parent` (copy to memory first, then mutate storage).
        address[] memory kids = _affiliate[user].children;
        for (uint256 i = 0; i < kids.length; i++) {
            address kid = kids[i];
            _childIndexPlus1[user][kid] = 0; // clear the stale index under the removed user
            _affiliate[kid].referral = parent;
            _addChild(parent, kid); // sets parent's index + totalDirects[parent]++
            emit AffiliateParentUpdated(kid, parent);
        }

        // Detach the user from its own sponsor and wipe its record.
        _removeChild(parent, user); // totalDirects[parent]-- for the user itself
        totalDirects[user] = 0;
        delete _affiliate[user]; // clears referral (→ address(0)) and the (already-migrated) children array

        isUser[user] = false;
        delete registeredAt[user];
        totalUsers -= 1;

        emit UserRemoved(user, parent);
    }

    /// @dev Append `child` to `parent`'s children with O(1)-removable index bookkeeping.
    /// @param parent The parent whose children array grows.
    /// @param child The child to append.
    function _addChild(address parent, address child) internal {
        address[] storage ch = _affiliate[parent].children;
        ch.push(child);
        _childIndexPlus1[parent][child] = ch.length; // stores index+1
        totalDirects[parent] += 1;
    }

    /// @dev Remove `child` from `parent`'s children in O(1) via the index map (swap-and-pop). No-op if absent.
    /// @param parent The parent whose children array shrinks.
    /// @param child The child to remove.
    function _removeChild(address parent, address child) internal {
        uint256 idxPlus1 = _childIndexPlus1[parent][child];
        if (idxPlus1 == 0) return; // not present
        address[] storage ch = _affiliate[parent].children;
        uint256 idx = idxPlus1 - 1;
        uint256 last = ch.length - 1;
        if (idx != last) {
            address moved = ch[last];
            ch[idx] = moved;
            _childIndexPlus1[parent][moved] = idx + 1; // fix the moved child's index
        }
        ch.pop();
        _childIndexPlus1[parent][child] = 0;
        if (totalDirects[parent] > 0) totalDirects[parent] -= 1;
    }

    /* ==================================================================== */
    /*                          ADMIN — PARAMETERS                          */
    /* ==================================================================== */

    /// @notice Pause or unpause the user-facing entry points.
    /// @param _paused True to pause, false to resume.
    /// @dev onlyAdmin. Emits PausedSet.
    function setPaused(bool _paused) external onlyAdmin {
        paused = _paused;
        emit PausedSet(_paused);
    }
 
}
