// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {ZyqorixAccounts} from "../accounts.sol";
import {ZyqorixToken} from "../zqrtoken.sol";
import {ZyqorixVesting} from "../vesting.sol";

contract ZyqorixVestingTest is Test {
    uint256 constant START = 1799971200;
    uint256 constant MONTH = 30 days;

    ZyqorixAccounts accounts;
    ZyqorixToken zqr;
    ZyqorixVesting vesting;

    address owner = address(this);
    address hub = makeAddr("hub");
    address alice = makeAddr("alice");
    address stranger = makeAddr("stranger");

    function setUp() public {
        vm.warp(START);
        accounts = new ZyqorixAccounts();
        accounts.addAdmin(hub);
        zqr = new ZyqorixToken();
        vesting = new ZyqorixVesting(address(accounts), address(zqr), 30 days);
        zqr.transfer(address(vesting), 1_000 ether); // operator funds with a plain transfer
    }

    function _grant(uint256 amount) internal {
        vm.prank(hub);
        vesting.createPosition(alice, amount);
    }

    function _claim() internal returns (uint256) {
        vm.prank(alice);
        return vesting.claim();
    }

    function test_operatorFundingShowsAsAvailable() public view {
        assertEq(vesting.available(), 1_000 ether);
        assertEq(vesting.totalReserved(), 0);
        assertEq(vesting.vestingMonths(), 60);
    }

    /// @dev The owner's sample: $100 at 0.001 USDT per ZQR over 60 months of 30 days.
    function test_sampleHundredDollarTier() public {
        zqr.transfer(address(vesting), 100_000 ether);
        _grant(100_000 ether);

        ZyqorixVesting.Position memory p = vesting.getPosition(alice, 0);
        assertEq(p.amount, 100_000 ether);
        assertEq(p.months, 60);
        assertEq(p.monthlyClaim, uint256(100_000 ether) / 60); // 1,666.66666667 ZQR
        assertEq(p.startTime, START);
        assertEq(p.lastClaim, 0);
        assertEq(p.totalClaim, 0);
        assertFalse(p.expired);

        vm.warp(START + 3 * MONTH);
        assertEq(_claim(), p.monthlyClaim * 3);
        assertEq(vesting.getPosition(alice, 0).lastClaim, START + 3 * MONTH);

        vm.warp(START + 60 * MONTH);
        assertEq(_claim(), 100_000 ether - p.monthlyClaim * 3);
        assertEq(zqr.balanceOf(alice), 100_000 ether);
        assertTrue(vesting.getPosition(alice, 0).expired);
    }

    function test_nothingMaturesBefore30Days() public {
        _grant(600 ether);
        vm.warp(START + MONTH - 1);
        assertEq(vesting.claimable(alice), 0);
        vm.prank(alice);
        vm.expectRevert("NOTHING_TO_CLAIM");
        vesting.claim();
    }

    function test_firstMonthMaturesAt30Days() public {
        _grant(600 ether);
        vm.warp(START + MONTH);
        assertEq(vesting.claimable(alice), 10 ether); // 600 / 60

        assertEq(_claim(), 10 ether);
        assertEq(zqr.balanceOf(alice), 10 ether);
        assertEq(vesting.totalReserved(), 590 ether);
        assertEq(vesting.getPosition(alice, 0).totalClaim, 10 ether);
    }

    function test_unclaimedMonthsAccumulate() public {
        _grant(600 ether);
        vm.warp(START + 3 * MONTH);
        assertEq(vesting.claimable(alice), 30 ether);
        assertEq(_claim(), 30 ether);
        assertEq(vesting.claimable(alice), 0);
    }

    function test_cannotClaimTwiceInOneMonth() public {
        _grant(600 ether);
        vm.warp(START + MONTH);
        _claim();
        vm.prank(alice);
        vm.expectRevert("NOTHING_TO_CLAIM");
        vesting.claim();

        vm.warp(START + 2 * MONTH);
        assertEq(_claim(), 10 ether);
    }

    /// @dev Claiming late doesn't move the schedule, so the part-month already passed isn't lost.
    function test_lateClaimKeepsTheSchedule() public {
        _grant(600 ether);
        vm.warp(START + MONTH + 29 days);
        assertEq(_claim(), 10 ether);
        vm.warp(START + 2 * MONTH);
        assertEq(_claim(), 10 ether);
    }

    function test_claimingEveryTwoMonths() public {
        _grant(600 ether + 7); // 7 wei of rounding dust
        uint256 monthly = uint256(600 ether + 7) / 60;
        uint256 paid;
        for (uint256 m = 2; m < 60; m += 2) {
            vm.warp(START + m * MONTH);
            assertEq(_claim(), monthly * 2);
            paid += monthly * 2;
        }
        vm.warp(START + 60 * MONTH);
        assertEq(_claim(), 600 ether + 7 - paid); // month 60 plus the dust
        assertEq(zqr.balanceOf(alice), 600 ether + 7);
        assertTrue(vesting.getPosition(alice, 0).expired);
    }

    function test_skippingTheFirstMonthLosesNothing() public {
        _grant(600 ether);
        vm.warp(START + MONTH);
        assertEq(vesting.claimable(alice), 10 ether); // matured, not collected
        vm.warp(START + 2 * MONTH + 5 days);
        assertEq(_claim(), 20 ether);
        vm.warp(START + 3 * MONTH);
        assertEq(_claim(), 10 ether);
    }

    function test_irregularClaimsPayExactlyTheMaturedMonths() public {
        _grant(600 ether);
        uint256[6] memory dayOf = [uint256(47), 95, 400, 433, 1000, 1799];
        uint256[6] memory matured = [uint256(1), 3, 13, 14, 33, 59];
        uint256 total;
        for (uint256 i = 0; i < 6; i++) {
            vm.warp(START + dayOf[i] * 1 days);
            uint256 due = matured[i] * 10 ether - total;
            assertEq(_claim(), due);
            total += due;
        }
        assertEq(vesting.getPosition(alice, 0).totalClaim, 590 ether);
        assertFalse(vesting.getPosition(alice, 0).expired);

        vm.warp(START + 5000 days); // long after the end
        assertEq(_claim(), 10 ether);
        assertEq(zqr.balanceOf(alice), 600 ether);
        assertTrue(vesting.getPosition(alice, 0).expired);
    }

    function test_neverClaimingUntilTheEndPaysEverything() public {
        _grant(600 ether);
        vm.warp(START + 200 * MONTH);
        assertEq(vesting.claimable(alice), 600 ether); // capped at the amount
        assertEq(_claim(), 600 ether);
        assertEq(vesting.totalReserved(), 0);
    }

    function test_lastMonthReleasesRoundingDustAndExpires() public {
        _grant(100 ether + 1);
        vm.warp(START + 59 * MONTH);
        assertEq(vesting.claimable(alice), (uint256(100 ether + 1) / 60) * 59);
        vm.warp(START + 60 * MONTH);
        assertEq(_claim(), 100 ether + 1);
        assertEq(vesting.totalReserved(), 0);
        assertTrue(vesting.getPosition(alice, 0).expired);

        vm.warp(START + 90 * MONTH);
        assertEq(vesting.claimable(alice), 0);
        vm.prank(alice);
        vm.expectRevert("NOTHING_TO_CLAIM");
        vesting.claim();
    }

    function test_positionsRunOnTheirOwnClocks() public {
        _grant(600 ether);
        vm.warp(START + 10 days);
        _grant(120 ether);

        vm.warp(START + MONTH);
        assertEq(vesting.claimable(alice), 10 ether); // the second isn't 30 days old yet
        vm.warp(START + MONTH + 10 days);
        assertEq(vesting.claimable(alice), 12 ether);
        assertEq(_claim(), 12 ether);
        assertEq(vesting.positionCount(alice), 2);
    }

    function test_positionsKeepTheirOwnMonths() public {
        _grant(600 ether); // 60 months
        vm.prank(hub);
        vesting.setVestingMonths(2);
        _grant(60 ether); // 2 months

        vm.warp(START + MONTH);
        assertEq(vesting.claimable(alice), 10 ether + 30 ether);
        assertEq(vesting.getPosition(alice, 1).months, 2);
    }

    function test_cannotPromiseMoreThanIsHeld() public {
        _grant(900 ether);
        vm.prank(hub);
        vm.expectRevert("INSUFFICIENT_POOL");
        vesting.createPosition(alice, 101 ether);

        zqr.transfer(address(vesting), 1 ether); // top-up
        _grant(101 ether);
        assertEq(vesting.available(), 0);
    }

    function test_ownerCanOnlyTakeUnreserved() public {
        _grant(900 ether);
        vm.expectRevert("INSUFFICIENT_POOL");
        vesting.withdrawUnreserved(owner, 101 ether);

        vm.prank(hub);
        vm.expectRevert("NOT_OWNER");
        vesting.withdrawUnreserved(hub, 1 ether);

        vesting.withdrawUnreserved(stranger, 100 ether);
        assertEq(zqr.balanceOf(stranger), 100 ether);
        vm.warp(START + 60 * MONTH);
        assertEq(_claim(), 900 ether);
    }

    function test_emergencyWithdrawMovesEverythingAndStopsThisContract() public {
        _grant(900 ether);
        vm.warp(START + MONTH);
        _claim(); // 15 paid, 885 still reserved, 985 held

        ZyqorixVesting next = new ZyqorixVesting(address(accounts), address(zqr), 30 days);
        vesting.emergencyWithdraw(address(next));

        assertEq(zqr.balanceOf(address(next)), 985 ether);
        assertEq(zqr.balanceOf(address(vesting)), 0);
        assertEq(vesting.migratedTo(), address(next));
        assertEq(vesting.available(), 0);

        vm.prank(alice);
        vm.expectRevert("MIGRATED");
        vesting.claim();
        vm.prank(hub);
        vm.expectRevert("MIGRATED");
        vesting.createPosition(alice, 1 ether);

        // The records stay readable for the new contract.
        assertEq(vesting.getPosition(alice, 0).amount, 900 ether);
        assertEq(vesting.getPosition(alice, 0).totalClaim, 15 ether);
        assertEq(next.available(), 985 ether);
    }

    function test_emergencyWithdrawCatchesLaterZqr() public {
        ZyqorixVesting next = new ZyqorixVesting(address(accounts), address(zqr), 30 days);
        vesting.emergencyWithdraw(address(next));
        zqr.transfer(address(vesting), 5 ether);
        assertEq(vesting.available(), 0);
        vesting.emergencyWithdraw(address(next));
        assertEq(zqr.balanceOf(address(next)), 1_005 ether);
    }

    function test_emergencyWithdrawGates() public {
        vm.prank(hub); // an admin is not enough
        vm.expectRevert("NOT_OWNER");
        vesting.emergencyWithdraw(address(zqr));

        vm.expectRevert("NOT_CONTRACT");
        vesting.emergencyWithdraw(stranger);

        vesting.withdrawUnreserved(owner, 1_000 ether);
        vm.expectRevert("NOTHING_TO_WITHDRAW");
        vesting.emergencyWithdraw(address(zqr));
    }

    function test_gates() public {
        vm.startPrank(stranger);
        vm.expectRevert("NOT_AUTH");
        vesting.createPosition(alice, 1 ether);
        vm.expectRevert("NOT_AUTH");
        vesting.setVestingMonths(6);
        vm.stopPrank();

        vm.expectRevert("ZERO_USER");
        vesting.createPosition(address(0), 1 ether);
        vm.expectRevert("ZERO_AMOUNT");
        vesting.createPosition(alice, 0);
        vm.expectRevert("BAD_MONTHS");
        vesting.setVestingMonths(0);
        vm.expectRevert("BAD_MONTHS");
        vesting.setVestingMonths(121);
    }

    function testFuzz_totalClaimedNeverExceedsGrant(uint96 raw, uint8 monthsRaw, uint32 jump) public {
        uint256 amount = bound(uint256(raw), 1, 1_000 ether);
        uint256 months = bound(uint256(monthsRaw), 1, 120);
        vesting.setVestingMonths(months);
        _grant(amount);

        uint256 at = START;
        uint256 paid;
        for (uint256 i = 0; i < 8; i++) {
            at += bound(uint256(jump) + i * 13 days, 1 days, 400 days);
            vm.warp(at);
            uint256 due = vesting.claimable(alice);
            assertLe(paid + due, amount);
            if (due > 0) paid += _claim();
        }
        vm.warp(at + 121 * MONTH);
        if (vesting.claimable(alice) > 0) paid += _claim();
        assertEq(paid, amount);
        assertEq(vesting.totalReserved(), 0);
        assertTrue(vesting.getPosition(alice, 0).expired);
    }
}
