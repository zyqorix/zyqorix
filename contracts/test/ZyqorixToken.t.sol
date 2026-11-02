// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {ZyqorixToken} from "../zqrtoken.sol";

contract ZyqorixTokenTest is Test {
    ZyqorixToken token;
    address alice = makeAddr("alice");

    function setUp() public {
        token = new ZyqorixToken();
    }

    function test_metadata() public view {
        assertEq(token.name(), "ZYQORIX");
        assertEq(token.symbol(), "ZQR");
        assertEq(token.decimals(), 18);
    }

    function test_fullSupplyGoesToDeployer() public view {
        assertEq(token.MAX_SUPPLY(), 1_000_000_000e18);
        assertEq(token.totalSupply(), token.MAX_SUPPLY());
        assertEq(token.balanceOf(address(this)), token.MAX_SUPPLY());
    }

    function test_ownershipIsRenounced() public view {
        assertEq(token.owner(), address(0));
    }

    function test_hasNoMintFunction() public {
        (bool ok, ) = address(token).call(abi.encodeWithSignature("mint(address,uint256)", alice, 1));
        assertFalse(ok);
    }

    function test_burnLowersTotalSupply() public {
        token.transfer(alice, 100 ether);
        vm.prank(alice);
        token.burn(40 ether);

        assertEq(token.balanceOf(alice), 60 ether);
        assertEq(token.totalSupply(), token.MAX_SUPPLY() - 40 ether);
    }

    function test_cannotBurnMoreThanBalance() public {
        vm.prank(alice);
        vm.expectRevert();
        token.burn(1);
    }
}
