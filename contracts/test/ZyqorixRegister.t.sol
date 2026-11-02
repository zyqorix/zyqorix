// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {ZyqorixAccounts} from "../accounts.sol";
import {ZyqorixFunder} from "../funder.sol";
import {ZyqorixGateway} from "../gateway.sol";
import {ZyqorixRegister} from "../register.sol";

contract MockToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 v) external { balanceOf[to] += v; }
    function approve(address s, uint256 v) external returns (bool) { allowance[msg.sender][s] = v; return true; }

    function transferFrom(address f, address to, uint256 v) external returns (bool) {
        allowance[f][msg.sender] -= v;
        balanceOf[f] -= v;
        balanceOf[to] += v;
        return true;
    }
}

contract MockRewards {
    mapping(address => uint256) public walletBalance;
    mapping(address => bool) public isActive;
    function creditDeposit(address u, uint256 v) external { walletBalance[u] += v; }
    function setActive(address u, bool v) external { isActive[u] = v; }
}

contract ZyqorixRegisterTest is Test {
    ZyqorixAccounts accounts;
    ZyqorixFunder funder;
    ZyqorixGateway gateway;
    ZyqorixRegister reg;
    MockToken usdt;
    MockRewards rewards;

    address owner = address(this);
    address hub = makeAddr("hub");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address stranger = makeAddr("stranger");

    function setUp() public {
        usdt = new MockToken();
        accounts = new ZyqorixAccounts();
        accounts.addAdmin(hub);
        funder = new ZyqorixFunder(address(accounts), address(usdt));
        gateway = new ZyqorixGateway(address(accounts), address(usdt), address(funder));
        funder.setGateway(address(gateway));
        rewards = new MockRewards();
        gateway.setRewards(address(rewards));
        reg = new ZyqorixRegister(address(accounts), address(gateway));
        accounts.addAdmin(address(reg));

        usdt.mint(alice, 100 ether);
        vm.prank(alice);
        usdt.approve(address(gateway), type(uint256).max);
    }

    function _register(address user, address sponsor) internal {
        vm.prank(user, user); // msg.sender and tx.origin
        reg.register(sponsor);
    }

    function _sponsor(address user) internal view returns (address s) {
        (s, ) = accounts.getAffiliate(user);
    }

    function test_defaultInitialDepositIs50() public view {
        assertEq(reg.initialDeposit(), 50 ether);
    }

    function test_registerJoinsTreeAndDeposits() public {
        vm.expectEmit(true, true, false, true);
        emit ZyqorixRegister.Registered(alice, owner, 50 ether);
        _register(alice, owner);

        assertTrue(accounts.isUser(alice));
        assertEq(_sponsor(alice), owner);
        assertEq(usdt.balanceOf(alice), 50 ether);
        assertEq(usdt.balanceOf(address(funder)), 50 ether);
        assertEq(usdt.balanceOf(address(gateway)), 0);
        assertEq(usdt.balanceOf(address(reg)), 0);
        assertEq(rewards.walletBalance(alice), 50 ether);
    }

    function test_invalidSponsorReverts() public {
        vm.prank(alice, alice);
        vm.expectRevert("SPONSOR_NOT_FOUND");
        reg.register(stranger);

        vm.prank(alice, alice);
        vm.expectRevert("SPONSOR_NOT_FOUND");
        reg.register(address(0));

        vm.prank(alice, alice);
        vm.expectRevert("SPONSOR_NOT_FOUND");
        reg.register(alice); // not registered yet, so also not a valid sponsor

        assertFalse(accounts.isUser(alice));
        assertEq(usdt.balanceOf(alice), 100 ether);
    }

    function test_cannotRegisterTwice() public {
        _register(alice, owner);
        vm.prank(alice, alice);
        vm.expectRevert("ALREADY_REGISTERED");
        reg.register(owner);
        assertEq(usdt.balanceOf(alice), 50 ether);
    }

    function test_memberCanSponsorNextUser() public {
        _register(alice, owner);
        rewards.setActive(alice, true);
        reg.setInitialDeposit(0);
        _register(bob, alice);
        assertEq(_sponsor(bob), alice);
        assertEq(accounts.totalDirects(alice), 1);
    }

    function test_failedDepositUndoesRegistration() public {
        vm.prank(bob, bob); // no allowance, no balance
        vm.expectRevert();
        reg.register(owner);
        assertFalse(accounts.isUser(bob));
        assertEq(accounts.totalUsers(), 1);
    }

    function test_zeroDepositNeedsNoApproval() public {
        vm.prank(hub);
        reg.setInitialDeposit(0);

        _register(bob, owner);

        assertTrue(accounts.isUser(bob));
        assertEq(usdt.balanceOf(address(funder)), 0);
        assertEq(rewards.walletBalance(bob), 0);
    }

    function test_changedDepositIsUsed() public {
        vm.prank(hub);
        reg.setInitialDeposit(75 ether);
        _register(alice, owner);
        assertEq(usdt.balanceOf(address(funder)), 75 ether);
    }

    function test_setInitialDepositIsAdminOnly() public {
        vm.prank(stranger);
        vm.expectRevert("NOT_AUTH");
        reg.setInitialDeposit(1 ether);
    }

    function test_contractCallerRejected() public {
        vm.expectRevert("CALLER_NOT_EOA");
        reg.register(owner); // this test contract is msg.sender, tx.origin differs
    }

    function test_pausedBlocksRegistration() public {
        accounts.setPaused(true);
        vm.prank(alice, alice);
        vm.expectRevert("PAUSED");
        reg.register(owner);

        accounts.setPaused(false);
        gateway.setPaused(true);
        vm.prank(alice, alice);
        vm.expectRevert("PAUSED");
        reg.register(owner);
        assertFalse(accounts.isUser(alice));
    }

    function test_registerMustBeAccountsAdmin() public {
        accounts.removeAdmin(address(reg));
        vm.prank(alice, alice);
        vm.expectRevert("NOT_AUTH");
        reg.register(owner);
    }

    function test_constructorChecks() public {
        vm.expectRevert("ZERO_ADDRESS");
        new ZyqorixRegister(address(0), address(gateway));
        vm.expectRevert("NOT_CONTRACT");
        new ZyqorixRegister(address(accounts), stranger);
    }
}
