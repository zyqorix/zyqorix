// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

/*
 * Dev/local USDT for ZYQORIX: a stand-in for BSC-mainnet Tether (BEP20) at the SAME address
 * (0x55d398326f99059fF775485246999027B3197955), which funder.sol, gateway.sol, liquidity.sol and
 * exchangerdisbursement.sol hardcode. The project copy of chain/src/usdt/USDT.sol (same code, renamed so
 * the two artifacts don't clash): tests `vm.etch` it at the address, and on anvil chain/script/deploy-usdt.js
 * places the shared copy there with `anvil_setCode`.
 *
 * Two deliberate design choices make it survive `setCode` (which copies CODE, not storage):
 *   1. name / symbol / decimals are `constant` → baked into bytecode, so they survive setCode.
 *   2. mint() is UNRESTRICTED (no owner/constructor state) → faucet minting works even though the
 *      target address has empty storage after setCode. LOCAL / TESTNET ONLY — never mainnet.
 *
 * Matches BSC-USDT's shape: 18 decimals, bool-returning transfer/transferFrom, infinite-allowance
 * shortcut. Balances/allowances live in storage and are filled by mint().
 */
contract USDTMock {
    string public constant name = "Tether USD";
    string public constant symbol = "USDT";
    uint8 public constant decimals = 18;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /// @notice Faucet mint. Unrestricted by design (see file header) — DEV/LOCAL ONLY.
    function mint(address to, uint256 amount) external {
        require(to != address(0), "USDT: mint to zero");
        totalSupply += amount;
        unchecked { balanceOf[to] += amount; }
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) {
            require(a >= amount, "USDT: insufficient allowance");
            unchecked { allowance[from][msg.sender] = a - amount; }
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(to != address(0), "USDT: transfer to zero");
        uint256 bal = balanceOf[from];
        require(bal >= amount, "USDT: insufficient balance");
        unchecked {
            balanceOf[from] = bal - amount;
            balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
    }
}
