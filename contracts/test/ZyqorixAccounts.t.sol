// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {ZyqorixAccounts} from "../accounts.sol";

contract ZyqorixAccountsTest is Test {
    ZyqorixAccounts accounts;

    address owner = address(this);
    address hub = makeAddr("hub");
    address a = makeAddr("a");
    address b = makeAddr("b");
    address c = makeAddr("c");

    function setUp() public {
        accounts = new ZyqorixAccounts();
        accounts.addAdmin(hub);
    }

    function _reg(address user, address sponsor) internal {
        vm.prank(hub);
        accounts.addUser(user, sponsor);
    }

    function _chain() internal {
        _reg(a, owner); // root -> a
        _reg(b, a);     // a -> b
        _reg(c, b);     // b -> c
    }

    function _sponsor(address user) internal view returns (address s) {
        (s, ) = accounts.getAffiliate(user);
    }

    function test_constructorSeedsRoot() public view {
        assertEq(accounts.root(), owner);
        assertTrue(accounts.isUser(owner));
        assertEq(accounts.totalUsers(), 1);
        assertFalse(accounts.isAdmin(owner)); // structural only; authority comes from owner()
        assertTrue(accounts.checkIsAdmin(owner));
    }

    function test_addUserBuildsTree() public {
        _chain();
        assertEq(accounts.totalUsers(), 4);
        assertEq(_sponsor(c), b);
        assertEq(accounts.totalDirects(a), 1);
    }

    function test_registeredAtIsRecordedAndCleared() public {
        assertGt(accounts.registeredAt(owner), 0);
        vm.warp(1_000_000);
        _reg(a, owner);
        assertEq(accounts.registeredAt(a), 1_000_000);

        accounts.removeUser(a);
        assertEq(accounts.registeredAt(a), 0);
    }

    function test_addUserGates() public {
        vm.prank(a);
        vm.expectRevert("NOT_AUTH");
        accounts.addUser(a, owner);

        vm.startPrank(hub);
        vm.expectRevert("ZERO_USER");
        accounts.addUser(address(0), owner);
        vm.expectRevert("SPONSOR_NOT_FOUND");
        accounts.addUser(a, b);
        accounts.addUser(a, owner);
        vm.expectRevert("ALREADY_REGISTERED");
        accounts.addUser(a, owner);
        vm.stopPrank();
    }

    function test_pauseBlocksRegistration() public {
        accounts.setPaused(true);
        vm.prank(hub);
        vm.expectRevert("PAUSED");
        accounts.addUser(a, owner);
    }

    function test_reparentMovesChildAndRejectsCycle() public {
        _chain();
        vm.expectRevert("CIRCULAR_PARENT");
        accounts.updateAffiliateParent(a, c);

        accounts.updateAffiliateParent(c, a);
        assertEq(_sponsor(c), a);
        assertEq(accounts.totalDirects(b), 0);
        assertEq(accounts.totalDirects(a), 2);

        vm.expectRevert("CANNOT_REPARENT_ROOT");
        accounts.updateAffiliateParent(owner, a);
    }

    function test_removeUserMigratesChildren() public {
        _chain();
        accounts.removeUser(b);

        assertFalse(accounts.isUser(b));
        assertEq(accounts.totalUsers(), 3);
        assertEq(_sponsor(c), a);
        assertEq(accounts.totalDirects(a), 1);

        vm.expectRevert("CANNOT_REMOVE_ROOT");
        accounts.removeUser(owner);
    }

    function test_getChildrenPaginates() public {
        _reg(a, owner);
        _reg(b, owner);
        _reg(c, owner);
        (address[] memory page, uint256 total) = accounts.getChildren(owner, 1, 5);
        assertEq(total, 3);
        assertEq(page.length, 2);
        assertEq(page[0], b);
        (page, ) = accounts.getChildren(owner, 9, 5);
        assertEq(page.length, 0);
    }

    function test_twoStepOwnership() public {
        accounts.transferOwnership(a);
        assertEq(accounts.owner(), owner);

        vm.prank(b);
        vm.expectRevert("NOT_PENDING_OWNER");
        accounts.acceptOwnership();

        vm.prank(a);
        accounts.acceptOwnership();
        assertEq(accounts.owner(), a);
        assertFalse(accounts.checkIsAdmin(owner));
    }

    function test_removeAdminRevokesAuth() public {
        accounts.removeAdmin(hub);
        vm.prank(hub);
        vm.expectRevert("NOT_AUTH");
        accounts.addUser(a, owner);
    }

    /// @dev Random add / remove / re-parent sequences must keep the tree whole after every step.
    function testFuzz_treeStaysConsistent(uint256 seed) public {
        address[] memory users = new address[](12);
        for (uint256 i = 0; i < users.length; i++) users[i] = address(uint160(0x5000 + i));

        for (uint256 step = 0; step < 150; step++) {
            uint256 x = uint256(keccak256(abi.encode(seed, step)));
            address p = users[x % 12];
            address q = users[(x >> 16) % 12];
            uint256 op = (x >> 32) % 3;

            if (op == 0) {
                if (!accounts.isUser(p)) accounts.addUser(p, accounts.isUser(q) && p != q ? q : owner);
            } else if (op == 1) {
                if (accounts.isUser(p)) accounts.removeUser(p);
            } else {
                try accounts.updateAffiliateParent(p, q) {} catch {}
            }
            _assertTree(users);
        }
    }

    function _assertTree(address[] memory users) internal view {
        uint256 live = 1; // root
        uint256 directs = accounts.totalDirects(owner);
        for (uint256 i = 0; i < users.length; i++) {
            address u = users[i];
            (, uint256 n) = accounts.getAffiliate(u);
            assertEq(n, accounts.totalDirects(u));
            if (!accounts.isUser(u)) {
                assertEq(n, 0);
                assertEq(_sponsor(u), address(0));
                continue;
            }
            live++;
            directs += n;

            // Every member reaches root through registered sponsors, and its sponsor lists it as a child.
            address s = _sponsor(u);
            (address[] memory kids, ) = accounts.getChildren(s, 0, type(uint256).max);
            bool listed;
            for (uint256 k = 0; k < kids.length; k++) if (kids[k] == u) listed = true;
            assertTrue(listed);

            address cursor = u;
            for (uint256 hops = 0; cursor != owner; hops++) {
                assertLt(hops, users.length); // more hops than members means a cycle
                cursor = _sponsor(cursor);
                assertTrue(accounts.isUser(cursor));
            }
        }
        assertEq(accounts.totalUsers(), live);
        assertEq(directs, live - 1); // everyone except root has exactly one sponsor
    }
}
