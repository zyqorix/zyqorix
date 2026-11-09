// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {ZyqorixAccounts} from "../accounts.sol";
import {ZyqorixFunder} from "../funder.sol";
import {ZyqorixGateway} from "../gateway.sol";
import {ZyqorixRewards} from "../rewards.sol";
import {ZQRMock} from "../zqrmock.sol";
import {ZyqorixVesting} from "../vesting.sol";
import {MockLiquidity, MockUsdt} from "./ZyqorixRewards.t.sol";

/// @dev The testnet clock from script/zyqorix/Deploy.s.sol: a day is 1 minute and a month is 30 minutes.
contract ZyqorixTestnetTimeTest is Test {
    /// @dev USDT's BSC mainnet address, hardcoded in funder, gateway, liquidity and the exchanger.
    address constant USDT_ADDR = 0x55d398326f99059fF775485246999027B3197955;
    address constant ZQR_ADDR = 0x43ADE7aE5E14e6dadD0f6967a0aDEADe56095e70;
    uint256 constant START = 1_800_000_000; // a whole number of 30-minute periods
    uint256 constant DAY = 1 minutes;
    uint256 constant MONTH = 30 minutes;

    ZyqorixAccounts accounts;
    ZyqorixFunder funder;
    ZyqorixGateway gateway;
    ZyqorixRewards rewards;
    ZyqorixVesting vesting;
    ZQRMock zqr;
    MockUsdt usdt;

    address owner = address(this);
    address trading = makeAddr("trading");
    address sponsor = makeAddr("sponsor");
    address alice = makeAddr("alice");

    function setUp() public {
        vm.warp(START);
        // USDT's mainnet address is hardcoded in the contracts: etch the mock there.
        vm.etch(USDT_ADDR, type(MockUsdt).runtimeCode);
        usdt = MockUsdt(USDT_ADDR);
        accounts = new ZyqorixAccounts();
        funder = new ZyqorixFunder(address(accounts));
        gateway = new ZyqorixGateway(address(accounts), address(funder));
        gateway.setWithdrawalCooldown(DAY);
        funder.setGateway(address(gateway));
        funder.setTradingWallet(trading);
        // ZQR's mainnet address is hardcoded in vesting.sol: etch the mock there and mint the full supply.
        vm.etch(ZQR_ADDR, type(ZQRMock).runtimeCode);
        zqr = ZQRMock(ZQR_ADDR);
        zqr.mint(address(this), zqr.MAX_SUPPLY());
        vesting = new ZyqorixVesting(address(accounts), MONTH);
        zqr.transfer(address(vesting), 1_000_000 ether);
        rewards = new ZyqorixRewards(address(accounts), address(gateway), address(vesting), DAY);
        accounts.addAdmin(address(rewards));
        gateway.setRewards(address(rewards));
        funder.setRewards(address(rewards));
        gateway.setLiquidity(address(new MockLiquidity(address(usdt), address(zqr))));

        usdt.mint(trading, 1_000_000 ether);
        vm.startPrank(trading);
        usdt.approve(address(funder), 1_000_000 ether);
        funder.fundRewards(1_000_000 ether);
        vm.stopPrank();

        _join(sponsor, owner);
        _join(alice, sponsor);
    }

    function _join(address user, address up) internal {
        accounts.addUser(user, up);
        usdt.mint(user, 1_000 ether);
        vm.prank(user);
        usdt.approve(address(gateway), type(uint256).max);
    }

    function _activate(address user) internal {
        vm.startPrank(user);
        gateway.deposit(address(usdt), 50 ether);
        rewards.activate(0);
        vm.stopPrank();
    }

    function test_dailyAccruesAndClaimsEveryMinute() public {
        _activate(alice);
        vm.warp(START + DAY - 1);
        assertEq(rewards.pendingDaily(alice), 0);

        vm.warp(START + DAY);
        assertEq(rewards.pendingDaily(alice), 0.5 ether);
        vm.prank(alice);
        rewards.claimDaily();
        assertEq(rewards.getUser(alice).nextClaim, START + 2 * DAY);

        vm.warp(START + 2 * DAY - 1);
        vm.prank(alice);
        vm.expectRevert("CLAIM_COOLDOWN");
        rewards.claimDaily();

        vm.warp(START + 2 * DAY);
        vm.prank(alice);
        assertEq(rewards.claimDaily(), 0.5 ether);
    }

    function test_tierCapsAfter300Minutes() public {
        _activate(alice);
        vm.warp(START + 299 * DAY);
        assertEq(rewards.pendingDaily(alice), 149.5 ether);
        vm.warp(START + 1_000 * DAY);
        assertEq(rewards.pendingDaily(alice), 150 ether);
    }

    function test_secondTierPairOpensAfter60Minutes() public {
        _activate(alice); // the counter runs from the first activation, at START
        vm.warp(START + 60 * DAY - 1);
        assertFalse(rewards.isTierUnlocked(alice, 2));
        vm.warp(START + 60 * DAY);
        assertTrue(rewards.isTierUnlocked(alice, 2));
    }

    function test_leadershipMonthClosesEvery30Minutes() public {
        assertEq(rewards.currentMonth(), START / MONTH);
        _activate(sponsor);
        _activate(alice);
        uint256 month = rewards.currentMonth();
        assertEq(rewards.monthVolume(month, sponsor), 50 ether);

        vm.warp(START + MONTH - 1);
        assertEq(rewards.pendingLeadership(sponsor), 0);

        vm.warp(START + MONTH);
        assertEq(rewards.currentMonth(), month + 1);
        assertGt(rewards.pendingLeadership(sponsor), 0);
    }

    function test_vestingMonthIs30Minutes() public {
        _activate(alice);
        uint256 monthly = vesting.getPosition(alice, 0).monthlyClaim;
        assertGt(monthly, 0);

        vm.warp(START + MONTH - 1);
        assertEq(vesting.claimable(alice), 0);
        vm.warp(START + MONTH);
        assertEq(vesting.claimable(alice), monthly);
        vm.warp(START + 60 * MONTH);
        assertEq(vesting.claimable(alice), vesting.getPosition(alice, 0).amount);
    }

    function test_withdrawalCooldownIs60Seconds() public {
        _activate(sponsor); // the deposit restarts the cooldown at START
        rewards.setAgent(sponsor, true);
        _activate(alice);

        vm.warp(START + DAY);
        vm.prank(sponsor);
        vm.expectRevert("COOLDOWN");
        gateway.withdrawAgent(2.5 ether);

        vm.warp(START + DAY + 1);
        vm.prank(sponsor);
        gateway.withdrawAgent(2.5 ether);
        assertEq(rewards.agentBalance(sponsor), 0);
    }

    function test_shortClockOnlyDeploysOnTheTestChain() public {
        address gatewayAddr = address(gateway);
        address accountsAddr = address(accounts);
        address vestingAddr = address(vesting);

        vm.expectRevert("BAD_DAY");
        new ZyqorixRewards(accountsAddr, gatewayAddr, vestingAddr, 2 minutes);
        vm.expectRevert("BAD_MONTH");
        new ZyqorixVesting(accountsAddr, 1 hours);

        vm.chainId(56);
        vm.expectRevert("BAD_DAY");
        new ZyqorixRewards(accountsAddr, gatewayAddr, vestingAddr, DAY);
        vm.expectRevert("BAD_MONTH");
        new ZyqorixVesting(accountsAddr, MONTH);

        assertEq(new ZyqorixRewards(accountsAddr, gatewayAddr, vestingAddr, 1 days).DAY(), 1 days);
        assertEq(new ZyqorixVesting(accountsAddr, 30 days).MONTH(), 30 days);
    }
}
