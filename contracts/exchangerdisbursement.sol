// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title  ExchangerDisbursement
 * @notice A shared receiving vault for exchanger settlements. Any USDT (or other asset) the
 *         contract holds is split EQUALLY among the registered exchanger wallets when a member
 *         triggers a disbursement.
 *
 * Roles:
 *   - owner  : manages the exchanger set (`addExchanger` / `removeExchanger`). Cannot withdraw funds.
 *   - member : any registered exchanger. Triggers `disburseFunding` (USDT) / `disburseToken` / `disburseNative`.
 *
 * Money model: the contract never keeps custody beyond a disbursement round — funds can only leave
 * split equally across the current members. Equal share = balance / count; the remainder (< count wei)
 * stays in the contract and is paid out next round. There is intentionally NO owner drain.
 *
 * Trust note: `owner` should register plain wallets (EOAs). For ERC20 (incl. USDT) a recipient can never
 * block a payout (plain-ERC20 `transfer` makes no callback). For NATIVE BNB, a recipient contract that
 * reverts on receive would block that batch — so keep native recipients as EOAs.
 *
 * @dev Members are held in a self-contained enumerable address set (array + 1-based index map,
 *      swap-pop removal) — no external set library, so the flattened source verifies warning-free.
 */
contract ExchangerDisbursement is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Default settlement asset: BSC USDT at its mainnet address (the anvil testnet has a mock there).
    IERC20 public constant usdt = IERC20(0x55d398326f99059fF775485246999027B3197955);

    // ── enumerable address set ──
    address[] private _members;            // the exchanger wallets (order not guaranteed after removals)
    mapping(address => uint256) private _memberIndex; // 1-based position in `_members`; 0 = not a member

    event ExchangerAdded(address indexed exchanger);
    event ExchangerRemoved(address indexed exchanger);
    event Disbursed(
        address indexed token, address indexed caller, uint256 total, uint256 share, uint256 count
    );
    event NativeDisbursed(address indexed caller, uint256 total, uint256 share, uint256 count);

    error ZeroAddress();
    error AlreadyExchanger();
    error NotExchanger();
    error NoExchangers();
    error NothingToDisburse();
    error NativeTransferFailed(address to);

    modifier onlyMember() {
        if (_memberIndex[msg.sender] == 0) revert NotExchanger();
        _;
    }

    /// @param owner_ membership admin (owner).
    constructor(address owner_) Ownable(owner_) {}

    // ─────────────────────────────── membership (owner) ───────────────────────────────

    /// @notice Register an exchanger wallet. onlyOwner.
    function addExchanger(address exchanger) external onlyOwner {
        if (exchanger == address(0)) revert ZeroAddress();
        if (_memberIndex[exchanger] != 0) revert AlreadyExchanger();
        _members.push(exchanger);
        _memberIndex[exchanger] = _members.length; // 1-based
        emit ExchangerAdded(exchanger);
    }

    /// @notice Deregister an exchanger wallet. onlyOwner. O(1) swap-pop.
    function removeExchanger(address exchanger) external onlyOwner {
        uint256 idx = _memberIndex[exchanger];
        if (idx == 0) revert NotExchanger();
        uint256 lastPos = _members.length; // 1-based count
        if (idx != lastPos) {
            address last = _members[lastPos - 1];
            _members[idx - 1] = last;
            _memberIndex[last] = idx;
        }
        _members.pop();
        delete _memberIndex[exchanger];
        emit ExchangerRemoved(exchanger);
    }

    // ─────────────────────────────── disbursement (members) ───────────────────────────

    /// @notice Split the contract's USDT balance equally across all exchangers. onlyMember.
    function disburseFunding() external onlyMember nonReentrant {
        _disburse(usdt);
    }

    /// @notice Split the contract's balance of an arbitrary ERC20 equally. onlyMember.
    ///         Covers "any asset received". For fee-on-transfer tokens recipients net slightly less.
    function disburseToken(IERC20 token) external onlyMember nonReentrant {
        if (address(token) == address(0)) revert ZeroAddress();
        _disburse(token);
    }

    /// @notice Split the contract's native BNB balance equally. onlyMember. (Recipients must be EOAs.)
    function disburseNative() external onlyMember nonReentrant {
        uint256 n = _members.length;
        if (n == 0) revert NoExchangers();
        uint256 bal = address(this).balance;
        uint256 share = bal / n;
        if (share == 0) revert NothingToDisburse();
        for (uint256 i; i < n; ++i) {
            (bool ok,) = _members[i].call{value: share}("");
            if (!ok) revert NativeTransferFailed(_members[i]);
        }
        emit NativeDisbursed(msg.sender, share * n, share, n);
    }

    function _disburse(IERC20 token) private {
        uint256 n = _members.length;
        if (n == 0) revert NoExchangers();
        uint256 bal = token.balanceOf(address(this));
        uint256 share = bal / n; // remainder (< n wei) stays for the next round
        if (share == 0) revert NothingToDisburse();
        for (uint256 i; i < n; ++i) {
            token.safeTransfer(_members[i], share);
        }
        emit Disbursed(address(token), msg.sender, share * n, share, n);
    }

    /// @notice Accept native BNB deposits (so it can be split via `disburseNative`).
    receive() external payable {}

    // ─────────────────────────────── views ────────────────────────────────────────────

    function isExchanger(address a) external view returns (bool) {
        return _memberIndex[a] != 0;
    }

    function exchangerCount() external view returns (uint256) {
        return _members.length;
    }

    function exchangerAt(uint256 i) external view returns (address) {
        return _members[i];
    }

    /// @notice Full member list (order not guaranteed). Fine for the expected small set.
    function exchangers() external view returns (address[] memory) {
        return _members;
    }

    /// @notice Pending equal share of `token` at the current balance/member count (0 if none).
    function pendingShare(IERC20 token) external view returns (uint256) {
        uint256 n = _members.length;
        if (n == 0) return 0;
        return token.balanceOf(address(this)) / n;
    }
}