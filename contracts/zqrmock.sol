// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

/*
 * Dev/local ZQR: a stand-in for the BSC-mainnet ZYQORIX token at the SAME address
 * (0x43ADE7aE5E14e6dadD0f6967a0aDEADe56095e70). Placed on a local/anvil chain via `anvil_setCode` so
 * vesting.sol and liquidity.sol, which hardcode that address, work unchanged on the testnet.
 * See chain/script/deploy-zqr.js. The USDT twin is chain/src/usdt/USDT.sol.
 *
 * Built to survive `setCode` (which copies CODE, not storage):
 *   1. name / symbol / decimals are `constant`, so they live in the bytecode.
 *   2. mint() is UNRESTRICTED (no owner or constructor state), so faucet minting works on the empty storage
 *      setCode leaves behind. LOCAL / TESTNET ONLY. The real token (zqrtoken.sol) has no mint.
 *
 * Matches the real token's surface: 18 decimals, bool-returning transfers, burn / burnFrom (the gateway burns
 * the ZQR it buys with the withdrawal fee), MAX_SUPPLY, and owner() = address(0) (the real one is renounced).
 */
contract ZQRMock {
    string public constant name = "ZYQORIX";
    string public constant symbol = "ZQR";
    uint8 public constant decimals = 18;
    uint256 public constant MAX_SUPPLY = 1_000_000_000 ether;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /// @notice Always address(0), like the renounced mainnet token.
    function owner() external pure returns (address) {
        return address(0);
    }

    /// @notice Faucet mint. Unrestricted by design (see file header). DEV/LOCAL ONLY.
    function mint(address to, uint256 amount) external {
        require(to != address(0), "ZQR: mint to zero");
        totalSupply += amount;
        unchecked { balanceOf[to] += amount; }
        emit Transfer(address(0), to, amount);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    function burnFrom(address from, uint256 amount) external {
        _spendAllowance(from, amount);
        _burn(from, amount);
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
        _spendAllowance(from, amount);
        _transfer(from, to, amount);
        return true;
    }

    function _spendAllowance(address from, uint256 amount) internal {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) {
            require(a >= amount, "ZQR: insufficient allowance");
            unchecked { allowance[from][msg.sender] = a - amount; }
        }
    }

    function _burn(address from, uint256 amount) internal {
        uint256 bal = balanceOf[from];
        require(bal >= amount, "ZQR: insufficient balance");
        unchecked {
            balanceOf[from] = bal - amount;
            totalSupply -= amount;
        }
        emit Transfer(from, address(0), amount);
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(to != address(0), "ZQR: transfer to zero");
        uint256 bal = balanceOf[from];
        require(bal >= amount, "ZQR: insufficient balance");
        unchecked {
            balanceOf[from] = bal - amount;
            balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
    }
}
