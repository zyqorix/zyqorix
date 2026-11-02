// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/*
 * ZYQORIX (ZQR)
 * BEP20 · 18 dp · maximum supply 1B
 *
 * The entire 1,000,000,000 ZQR is minted to the deployer at construction. There is NO mint function, so
 * supply can never inflate; it can only fall through burns. The gateway burns the ZQR it buys with the
 * withdrawal fee, and `totalSupply` drops by that amount. BEP20 is ERC20-compatible (bool-returning
 * transfers, 18 decimals), so no BSC-specific interface is required for wallets or BscScan.
 *
 * Ownership is RENOUNCED in the constructor: `owner()` returns address(0) immediately after deployment, so
 * anyone can verify on-chain that the token has no admin. No owner-gated levers exist. Inherits OpenZeppelin
 * `Ownable` purely to expose the standard `owner()` view.
 */

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract ZyqorixToken is ERC20Burnable, Ownable {
    uint256 public constant MAX_SUPPLY = 1_000_000_000 ether;

    constructor() ERC20("ZYQORIX", "ZQR") Ownable(msg.sender) {
        _mint(msg.sender, MAX_SUPPLY);
        renounceOwnership();
    }
}
