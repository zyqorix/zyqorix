// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test, stdStorage, StdStorage} from "forge-std/Test.sol";
import {ZyqorixAccounts} from "../accounts.sol";
import {ZyqorixFunder} from "../funder.sol";
import {ZyqorixGateway} from "../gateway.sol";
import {ZyqorixRewards} from "../rewards.sol";
import {ZyqorixToken} from "../zqrtoken.sol";
import {ZyqorixVesting} from "../vesting.sol";

contract MockUsdt {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 v) external { balanceOf[to] += v; }
    function approve(address s, uint256 v) external returns (bool) { allowance[msg.sender][s] = v; return true; }

    function transfer(address to, uint256 v) external returns (bool) {
        balanceOf[msg.sender] -= v;
        balanceOf[to] += v;
        return true;
    }

    function transferFrom(address f, address to, uint256 v) external returns (bool) {
        allowance[f][msg.sender] -= v;
        balanceOf[f] -= v;
        balanceOf[to] += v;
        return true;
    }
}

/// @dev 1 USDT = 2 ZQR. Takes the activation's liquidity share like addLiquidityUSDT.
contract MockLiquidity {
    address public USDT;
    address public TOKEN;
    bool public fail;

    constructor(address usdt, address token) { USDT = usdt; TOKEN = token; }
    function setFail(bool v) external { fail = v; }
    function convertToken(address, uint256 amountIn) external pure returns (uint256) { return amountIn * 2; }

    function addLiquidityUSDT(uint256 amount, uint24, uint256) external returns (uint256) {
        require(!fail, "LP_FAILED");
        MockUsdt(USDT).transferFrom(msg.sender, address(this), amount);
        return amount;
    }

    function swapUSDTToToken(uint256, uint24, address, uint256) external pure returns (uint256) {
        revert("NO_SWAP");
    }
}

contract ZyqorixRewardsTest is Test {
    using stdStorage for StdStorage;

    uint256 constant START = 1_800_000_000;
    uint256 constant DAY = 1 days;
    uint256 constant BASE = 1_000_000 ether;
    uint256 constant FEB_01 = 1801440000; // START is 2027-01-15
    uint256 constant MAR_01 = 1803859200;
    uint256 constant APR_01 = 1806537600;

    ZyqorixAccounts accounts;
    ZyqorixFunder funder;
    ZyqorixGateway gateway;
    ZyqorixRewards rewards;
    ZyqorixVesting vesting;
    ZyqorixToken zqr;
    MockUsdt usdt;
    MockLiquidity lp;

    address owner = address(this);
    address hub = makeAddr("hub");
    address trading = makeAddr("trading");
    address sponsor = makeAddr("sponsor");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        vm.warp(START);
        _deploy();
        _reserve(BASE);
    }

    function _deploy() internal {
        usdt = new MockUsdt();
        accounts = new ZyqorixAccounts();
        accounts.addAdmin(hub);
        funder = new ZyqorixFunder(address(accounts), address(usdt));
        gateway = new ZyqorixGateway(address(accounts), address(usdt), address(funder));
        gateway.setMinDeposit(0); // these tests size deposits freely; ZyqorixFlow tests the minimum
        funder.setGateway(address(gateway));
        funder.setTradingWallet(trading);
        zqr = new ZyqorixToken();
        vesting = new ZyqorixVesting(address(accounts), address(zqr), 30 days);
        zqr.transfer(address(vesting), 1_000_000 ether);
        rewards = new ZyqorixRewards(address(accounts), address(gateway), address(vesting), 1 days);
        accounts.addAdmin(address(rewards));
        gateway.setRewards(address(rewards));
        funder.setRewards(address(rewards));
        lp = new MockLiquidity(address(usdt), address(zqr));
        gateway.setLiquidity(address(lp));

        _join(sponsor, owner);
        _join(alice, sponsor);
    }

    function _join(address user, address up) internal {
        accounts.addUser(user, up);
        usdt.mint(user, 100_000 ether);
        vm.prank(user);
        usdt.approve(address(gateway), type(uint256).max);
    }

    function _fund(address user, uint256 amount) internal {
        vm.prank(user);
        gateway.deposit(address(usdt), amount);
    }

    /// @dev Jumps `user` straight to `tier`, so a test can look at one tier alone. ZyqorixFlow tests the tier order.
    function _setNext(address user, uint256 tier) internal {
        stdstore.target(address(rewards)).sig("nextTier(address)").with_key(user).checked_write(tier);
    }

    function _activate(address user, uint256 tier) internal {
        _fund(user, rewards.tierPrice(tier));
        _setNext(user, tier);
        vm.prank(user);
        rewards.activate(tier);
    }

    function _claim(address user) internal returns (uint256) {
        vm.prank(user);
        return rewards.claimDaily();
    }

    /// @dev Pay trading capital back, then `profit` on top, so the reward pool receives exactly `profit`.
    function _reserve(uint256 profit) internal {
        uint256 owed = funder.tradingCapitalOut() - funder.tradingCapitalReturned();
        usdt.mint(trading, owed + profit);
        vm.startPrank(trading);
        usdt.approve(address(funder), owed + profit);
        funder.fundRewards(owed + profit);
        vm.stopPrank();
    }

    /* ---------------------------- Activation --------------------------- */
    function test_tierPrices() public view {
        assertEq(rewards.tierPrice(0), 50 ether);
        assertEq(rewards.tierPrice(1), 100 ether);
        assertEq(rewards.tierPrice(2), 200 ether);
        assertEq(rewards.tierPrice(3), 400 ether);
        assertEq(rewards.tierPrice(4), 800 ether);
        assertEq(rewards.tierPrice(5), 1_600 ether);
    }

    function test_activationSpendsWalletAndAddsCapping() public {
        _activate(alice, 1);
        assertEq(rewards.walletBalance(alice), 0);
        assertEq(rewards.capping(alice), 300 ether);
        assertEq(rewards.tierCapping(alice, 1), 300 ether);
        assertEq(rewards.activeValue(alice), 100 ether);
    }

    function test_distributionOfA100Activation() public {
        _activate(sponsor, 1); // active sponsor, no referral paid upward because root is inactive
        uint256 funderBefore = usdt.balanceOf(address(funder));
        uint256 tradingBefore = usdt.balanceOf(trading);
        uint256 lpBefore = usdt.balanceOf(address(lp));
        rewards.setAgent(sponsor, true);

        _activate(alice, 1);

        assertEq(usdt.balanceOf(address(lp)) - lpBefore, 50 ether);
        assertEq(usdt.balanceOf(trading) - tradingBefore, 10 ether);
        assertEq(usdt.balanceOf(address(funder)) - funderBefore, 40 ether); // 20 buffer, 5 referral + 5 unpaid, 5 agent, 5 leadership
        assertEq(rewards.walletBalance(sponsor), 5 ether);
        assertEq(rewards.agentBalance(sponsor), 5 ether);
        assertEq(rewards.leadershipPool(), 10 ether); // both activations
        assertEq(funder.tradingCapitalOut(), 20 ether);
    }

    function test_vestingPositionIsWorthTheTier() public {
        _activate(alice, 1);
        assertEq(vesting.positionCount(alice), 1);
        assertEq(vesting.getPosition(alice, 0).amount, 200 ether); // $100 at 2 ZQR per USDT
    }

    function test_activationGoesThroughWhenVestingIsEmpty() public {
        vesting.withdrawUnreserved(owner, vesting.available());
        _fund(alice, 50 ether);

        vm.expectEmit(true, true, false, true);
        emit ZyqorixRewards.VestingSkipped(alice, 0, 100 ether); // $50 at 2 ZQR per USDT
        vm.expectEmit(true, true, false, true);
        emit ZyqorixRewards.Activated(alice, 0, 50 ether, 0);
        vm.prank(alice);
        rewards.activate(0);

        assertEq(vesting.positionCount(alice), 0);
        assertEq(rewards.walletBalance(alice), 0);
        vm.warp(block.timestamp + 1 days);
        assertEq(rewards.pendingDaily(alice), 0.5 ether); // the rewards still run
    }

    function test_noPartialPositionWhenVestingIsShort() public {
        vesting.withdrawUnreserved(owner, vesting.available() - 99 ether);
        _activate(alice, 0); // worth 100 ZQR, 99 held
        assertEq(vesting.positionCount(alice), 0);
        assertEq(vesting.available(), 99 ether);
    }

    function test_exactVestingBalanceStillCreatesAPosition() public {
        vesting.withdrawUnreserved(owner, vesting.available() - 100 ether);
        _activate(alice, 0);
        assertEq(vesting.positionCount(alice), 1);
        assertEq(vesting.available(), 0);
    }

    function test_vestingCanBeReplaced() public {
        ZyqorixVesting next = new ZyqorixVesting(address(accounts), address(zqr), 30 days);
        vesting.emergencyWithdraw(address(next));
        _activate(alice, 0); // the old contract has stopped: no position, no revert
        assertEq(vesting.positionCount(alice), 0);

        rewards.setVesting(address(next));
        _activate(alice, 1);
        assertEq(next.positionCount(alice), 1);
    }

    function test_setVestingGates() public {
        vm.prank(alice);
        vm.expectRevert("NOT_AUTH");
        rewards.setVesting(address(vesting));
        vm.expectRevert("NOT_CONTRACT");
        rewards.setVesting(alice);
    }

    function test_failedLiquidityStaysInFunder() public {
        lp.setFail(true);
        _activate(alice, 1);
        assertEq(usdt.balanceOf(address(lp)), 0);
        assertEq(usdt.balanceOf(address(funder)), BASE + 90 ether); // everything except trading
        assertEq(usdt.allowance(address(funder), address(lp)), 0);
    }

    function test_activationGates() public {
        vm.prank(alice);
        vm.expectRevert("INSUFFICIENT_WALLET");
        rewards.activate(0);

        vm.prank(alice);
        vm.expectRevert("BAD_TIER");
        rewards.activate(6);

        vm.prank(bob);
        vm.expectRevert("NOT_REGISTERED");
        rewards.activate(0);

        _activate(alice, 0);
        _fund(alice, 50 ether);
        vm.prank(alice);
        vm.expectRevert("TIER_USED");
        rewards.activate(0);

        gateway.setPaused(true);
        vm.prank(alice);
        vm.expectRevert("PAUSED");
        rewards.activate(1);
    }

    /* ----------------------------- Unlocks ----------------------------- */
    function test_firstPairOpenAtRegistration() public {
        assertTrue(rewards.isTierUnlocked(alice, 0));
        assertTrue(rewards.isTierUnlocked(alice, 1));
        assertFalse(rewards.isTierUnlocked(alice, 2));
        _fund(alice, 200 ether);
        _setNext(alice, 2);
        vm.prank(alice);
        vm.expectRevert("TIER_LOCKED");
        rewards.activate(2);
    }

    function test_dayCountersUnlockLaterPairs() public {
        vm.warp(START + 60 * DAY - 1);
        assertFalse(rewards.isTierUnlocked(alice, 2));
        vm.warp(START + 60 * DAY);
        assertTrue(rewards.isTierUnlocked(alice, 3));
        assertFalse(rewards.isTierUnlocked(alice, 4));
        vm.warp(START + 120 * DAY);
        assertTrue(rewards.isTierUnlocked(alice, 5));
    }

    function test_cappingBothTiersUnlocksEarly() public {
        // alice's referrals use up her capping before day 60
        _activate(alice, 0); // 150 capping
        _activate(alice, 1); // 300 capping
        for (uint256 i = 0; i < 100; i++) {
            address child = address(uint160(0x9000 + i));
            _join(child, alice);
            _fund(child, 1_600 ether);
            vm.warp(START + (i + 1) * 60); // stay well inside 60 days
            if (rewards.capping(alice) == 0) break;
            uint256 tier = i % 2;
            _setNext(child, tier);
            vm.prank(child);
            rewards.activate(tier);
        }
        assertEq(rewards.capping(alice), 0);
        assertTrue(rewards.isTierUnlocked(alice, 2));
        assertFalse(rewards.isTierUnlocked(alice, 4));
    }

    function test_onlyOneCappedTierDoesNotUnlock() public {
        _activate(alice, 0);
        vm.warp(START + 59 * DAY); // $0.50 a day can't reach $150 by day 59
        assertFalse(rewards.isTierUnlocked(alice, 2));
    }

    /* ----------------------------- Referral ---------------------------- */
    function test_referralIs5PercentBelowFiveActiveDirects() public {
        _activate(sponsor, 1);
        _activate(alice, 1);
        assertEq(rewards.activeDirects(sponsor), 1);
        assertEq(rewards.walletBalance(sponsor), 5 ether);
    }

    function test_referralIs10PercentFromFiveActiveDirects() public {
        _activate(sponsor, 1);
        for (uint256 i = 0; i < 4; i++) {
            address child = address(uint160(0x7000 + i));
            _join(child, sponsor);
            _activate(child, 0); // 5% of 50 each
        }
        assertEq(rewards.activeDirects(sponsor), 4);
        assertEq(rewards.walletBalance(sponsor), 10 ether);

        _activate(alice, 1); // the fifth active direct counts for its own activation
        assertEq(rewards.activeDirects(sponsor), 5);
        assertEq(rewards.walletBalance(sponsor), 20 ether); // + 10% of 100
    }

    function test_inactiveSponsorEarnsNothingAndNothingPassesUp() public {
        _activate(alice, 1);
        assertEq(rewards.walletBalance(sponsor), 0);
        assertEq(rewards.walletBalance(owner), 0);
    }

    function test_referralIsLimitedToRemainingCapping() public {
        _activate(sponsor, 0); // 150 capping
        address first = address(uint160(0x5F00));
        _join(first, sponsor);
        _activate(first, 0); // 2.50 referral, so capping doesn't land exactly on zero
        for (uint256 i = 0; i < 30; i++) {
            address child = address(uint160(0x6000 + i));
            _join(child, sponsor);
            _activate(child, 1);
            if (rewards.capping(sponsor) < 10 ether) break;
        }
        uint256 left = rewards.capping(sponsor);
        uint256 wallet = rewards.walletBalance(sponsor);
        assertGt(left, 0);

        _activate(alice, 1);

        assertEq(rewards.capping(sponsor), 0);
        assertEq(rewards.walletBalance(sponsor), wallet + left);
        assertEq(rewards.activeValue(sponsor), 0); // inactive
    }

    function test_cappingUsesOldestTierFirst() public {
        _activate(sponsor, 1); // 300, oldest
        _activate(sponsor, 0); // 150
        _activate(alice, 1);   // 5 referral
        assertEq(rewards.tierCapping(sponsor, 1), 295 ether);
        assertEq(rewards.tierCapping(sponsor, 0), 150 ether);
    }

    function test_deactivationStopsCountingAsActiveDirect() public {
        _activate(sponsor, 0);
        _activate(alice, 0);
        assertEq(rewards.activeDirects(sponsor), 1);

        vm.warp(START + 301 * DAY);
        _claim(alice); // settles her full capping
        assertEq(rewards.capping(alice), 0);
        assertEq(rewards.activeDirects(sponsor), 0);
    }

    /* ------------------------------ Agents ----------------------------- */
    function test_agentWalkStartsAtTheMember() public {
        rewards.setAgent(alice, true);
        _activate(alice, 1);
        assertEq(rewards.agentBalance(alice), 5 ether);
    }

    function test_firstActiveAgentUpTheTreeEarns() public {
        rewards.setAgent(sponsor, true);
        _activate(sponsor, 0);
        _activate(alice, 1);
        assertEq(rewards.agentBalance(sponsor), 7.5 ether); // 2.5 own + 5 from alice
    }

    function test_newAgentBreaksAwayFromUpperAgent() public {
        rewards.setAgent(sponsor, true);
        _activate(sponsor, 0);
        rewards.setAgent(alice, true);
        _join(bob, alice);
        _activate(alice, 0);
        _activate(bob, 1);
        assertEq(rewards.agentBalance(alice), 7.5 ether);
        assertEq(rewards.agentBalance(sponsor), 2.5 ether); // nothing from alice's network
    }

    function test_inactiveAgentIsSkipped() public {
        rewards.setAgent(owner, false);
        rewards.setAgent(alice, true); // alice has no capping when bob activates
        rewards.setAgent(sponsor, true);
        _activate(sponsor, 0);
        _join(bob, alice);
        _activate(bob, 1);
        assertEq(rewards.agentBalance(alice), 0);
        assertEq(rewards.agentBalance(sponsor), 7.5 ether);
    }

    function test_agentRewardUsesNoCapping() public {
        rewards.setAgent(sponsor, true);
        _activate(sponsor, 0);
        uint256 cappingBefore = rewards.capping(sponsor);
        rewards.setDistribution(5_000, 1_000, 0, 0, 500, 500);
        _activate(alice, 1);
        assertEq(rewards.capping(sponsor), cappingBefore);
        assertEq(rewards.agentBalance(sponsor), 7.5 ether);
    }

    function test_noAgentWithinLimitLeavesShareInFunder() public {
        rewards.setAgent(sponsor, true);
        _activate(sponsor, 0);
        rewards.setAgentWalkLimit(1); // only alice is checked
        _activate(alice, 1);
        assertEq(rewards.agentBalance(sponsor), 2.5 ether);
    }

    function test_agentWithdrawsWithNoFee() public {
        rewards.setAgent(alice, true);
        _activate(alice, 1);
        uint256 before = usdt.balanceOf(alice);
        vm.warp(START + DAY + 1);
        vm.prank(alice);
        gateway.withdrawAgent(5 ether);
        assertEq(usdt.balanceOf(alice), before + 5 ether);
        assertEq(rewards.agentBalance(alice), 0);
    }

    function test_demotedAgentKeepsBalanceButCannotWithdraw() public {
        rewards.setAgent(alice, true);
        _activate(alice, 1);
        vm.prank(owner);
        rewards.setAgent(alice, false);
        vm.warp(START + DAY + 1);

        vm.prank(alice);
        vm.expectRevert("NOT_AGENT");
        gateway.withdrawAgent(5 ether);
        assertEq(rewards.agentBalance(alice), 5 ether);

        vm.prank(owner);
        rewards.setAgent(alice, true);
        vm.prank(alice);
        gateway.withdrawAgent(5 ether);
        assertEq(rewards.agentBalance(alice), 0);
    }

    /* -------------------------- Trading profit -------------------------- */
    function test_capitalMustReturnBeforeAnyPoolMoney() public {
        _activate(alice, 1); // 10 capital out
        uint256 pool = funder.rewardPool();
        uint256 free = rewards.unreservedPool();
        usdt.mint(trading, 15 ether);
        vm.startPrank(trading);
        usdt.approve(address(funder), 15 ether);

        funder.fundRewards(6 ether);
        assertEq(funder.rewardPool(), pool);
        assertEq(funder.tradingCapitalReturned(), 6 ether);

        funder.fundRewards(9 ether); // 4 capital, 5 to the pool
        vm.stopPrank();
        assertEq(funder.rewardPool(), pool + 5 ether);
        assertEq(funder.capitalHeld(), 10 ether);
        assertEq(rewards.unreservedPool(), free + 5 ether);
    }

    function test_plainTransferIsNotReserve() public {
        _activate(alice, 1);
        uint256 pool = funder.rewardPool();
        uint256 free = rewards.unreservedPool();
        usdt.mint(address(funder), 1_000 ether);
        assertEq(funder.rewardPool(), pool);
        assertEq(rewards.unreservedPool(), free);
    }

    function test_redeployedCapitalMustComeBackToo() public {
        _activate(alice, 1);
        _reserve(0);
        uint256 pool = funder.rewardPool();
        funder.redeployCapital(10 ether);
        assertEq(usdt.balanceOf(trading), 20 ether); // its original 10 plus the redeployed 10
        assertEq(funder.capitalHeld(), 0);

        vm.expectRevert("INSUFFICIENT_CAPITAL");
        funder.redeployCapital(1);

        usdt.mint(trading, 3 ether);
        vm.startPrank(trading);
        usdt.approve(address(funder), 13 ether);
        funder.fundRewards(13 ether);
        vm.stopPrank();
        assertEq(funder.rewardPool(), pool + 3 ether);
    }

    function test_onlyFunderCanAddProfit() public {
        vm.expectRevert("NOT_FUNDER");
        rewards.notifyProfit(1 ether);
    }

    function test_activationFlowsAreRewardsOnly() public {
        vm.expectRevert("NOT_REWARDS");
        funder.sendToTrading(1 ether);
        vm.expectRevert("NOT_REWARDS");
        funder.sendToLiquidity(address(lp), 1 ether, 300);
        vm.expectRevert("NOT_REWARDS");
        funder.drawRewardPool(1 ether);
    }

    /* --------------------------- Daily rewards -------------------------- */
    function test_activationRejectedWithoutFullReserve() public {
        _deploy(); // an empty reward pool
        _fund(alice, 100 ether);
        _setNext(alice, 1);
        vm.prank(alice);
        vm.expectRevert("INSUFFICIENT_REWARD_POOL");
        rewards.activate(1);

        _reserve(299 ether);
        vm.prank(alice);
        vm.expectRevert("INSUFFICIENT_REWARD_POOL");
        rewards.activate(1);

        _reserve(1 ether);
        vm.prank(alice);
        rewards.activate(1);
        assertEq(rewards.unreservedPool(), 0);
        assertEq(rewards.totalCapping(), 300 ether);
    }

    function test_oneDayPaysExactlyOnePercent() public {
        _activate(alice, 1);
        vm.warp(START + DAY);
        assertEq(_claim(alice), 1 ether); // $100 tier
        assertEq(rewards.walletBalance(alice), 1 ether);
        assertEq(funder.rewardPool(), BASE - 1 ether);
    }

    function test_fixedAmountDoesNotDependOnOtherMembers() public {
        _activate(alice, 0);
        _join(bob, sponsor);
        _activate(bob, 1);
        vm.warp(START + DAY);
        assertEq(_claim(alice), 0.5 ether);
        assertEq(_claim(bob), 1 ether);
    }

    function test_unclaimedDaysAccumulate() public {
        _activate(alice, 1);
        vm.warp(START + 10 * DAY);
        assertEq(_claim(alice), 10 ether);
    }

    function test_partialDayPaysNothing() public {
        _activate(alice, 1);
        vm.warp(START + DAY - 1);
        vm.prank(alice);
        vm.expectRevert("NOTHING_TO_CLAIM");
        rewards.claimDaily();
    }

    function test_rateFallsWhenOldestTierCaps() public {
        _activate(alice, 0); // $0.50 a day, 150 capping
        _activate(alice, 1); // $1 a day, 300 capping
        // $1.50 a day caps the $50 tier at day 100, then $1 a day for the last 300.
        vm.warp(START + 100 * DAY);
        assertEq(_claim(alice), 150 ether);
        assertEq(rewards.tierCapping(alice, 0), 0);
        assertEq(rewards.activeValue(alice), 100 ether);

        vm.warp(START + 150 * DAY);
        assertEq(_claim(alice), 50 ether);
    }

    function test_longGapStepsThroughEveryTier() public {
        _activate(alice, 0);
        _activate(alice, 1);
        vm.warp(START + 1_000 * DAY);
        assertEq(_claim(alice), 450 ether);
        assertEq(rewards.capping(alice), 0);
        assertEq(rewards.activeValue(alice), 0);
    }

    function test_referralFreesReserve() public {
        _activate(sponsor, 1);
        uint256 free = rewards.unreservedPool();
        _activate(alice, 1); // reserves 300, sponsor uses 5 capping
        assertEq(rewards.unreservedPool(), free - 300 ether + 5 ether);
        assertEq(rewards.totalCapping(), 300 ether + 295 ether);
    }

    function test_claimOncePer24Hours() public {
        _activate(alice, 1);
        _reserve(1_000 ether);
        vm.warp(START + DAY);
        _claim(alice);
        vm.warp(START + DAY + DAY - 1);
        vm.prank(alice);
        vm.expectRevert("CLAIM_COOLDOWN");
        rewards.claimDaily();
        vm.warp(START + DAY + DAY);
        assertEq(_claim(alice), 1 ether);
    }

    function test_dailyUsesCappingAndEndsTheTier() public {
        _activate(alice, 0); // $50, 150 capping
        vm.warp(START + 300 * DAY);
        assertEq(_claim(alice), 150 ether); // $0.50 × 300
        assertEq(rewards.capping(alice), 0);
        assertEq(rewards.activeValue(alice), 0);
        assertEq(rewards.totalActiveValue(), 0);

        vm.warp(START + 400 * DAY);
        vm.prank(alice);
        vm.expectRevert("NOTHING_TO_CLAIM");
        rewards.claimDaily();
    }

    function test_cappedTierStaysUsedAndTheNextOneOpens() public {
        _activate(alice, 0);
        vm.warp(START + 300 * DAY);
        _claim(alice);
        vm.startPrank(alice);
        vm.expectRevert("TIER_USED");
        rewards.activate(0);
        rewards.activate(1); // paid from her 150 wallet
        vm.stopPrank();
        assertEq(rewards.capping(alice), 300 ether);
        assertEq(rewards.walletBalance(alice), 50 ether);
    }

    function test_claimedRewardsCanBeWithdrawn() public {
        _activate(alice, 0);
        vm.warp(START + 40 * DAY);
        _claim(alice); // $20
        vm.warp(START + 41 * DAY);
        uint256 before = usdt.balanceOf(alice);
        vm.prank(alice);
        gateway.withdraw(20 ether);
        assertEq(usdt.balanceOf(alice), before + 18 ether); // 20 minus the 10% fee
    }

    /* ------------------------- Generation bonus ------------------------- */
    /// @dev users[0] sits under sponsor; each later user sits under the one before. All activate $100.
    function _chain(uint256 n) internal returns (address[] memory users) {
        _activate(sponsor, 1);
        users = new address[](n);
        address up = sponsor;
        for (uint256 i = 0; i < n; i++) {
            users[i] = _child(500 + i, up, 1);
            up = users[i];
        }
    }

    function test_eachOfTenLevelsEarnsTenPercentOfTheClaim() public {
        address[] memory users = _chain(12);
        vm.warp(START + 10 * DAY);
        address claimer = users[11];
        assertEq(_claim(claimer), 10 ether);

        for (uint256 i = 1; i <= 10; i++) {
            assertEq(rewards.generationBalance(users[11 - i]), 1 ether);
        }
        assertEq(rewards.generationBalance(users[0]), 0); // the 11th level is outside the walk
        assertEq(rewards.generationBalance(sponsor), 0);
    }

    function test_oneUsdtClaimPaysPointOneEach() public {
        address[] memory users = _chain(2);
        vm.warp(START + DAY);
        _claim(users[1]);
        assertEq(rewards.generationBalance(users[0]), 0.1 ether);
        assertEq(rewards.generationBalance(sponsor), 0.1 ether);
    }

    function test_generationUsesTheSponsorsCapping() public {
        address[] memory users = _chain(1);
        vm.warp(START + DAY);
        uint256 before = rewards.capping(sponsor);
        uint256 daily = rewards.pendingDaily(sponsor);
        _claim(users[0]);
        assertEq(rewards.capping(sponsor), before - daily - 0.1 ether);
        assertEq(rewards.generationBalance(sponsor), 0.1 ether);
    }

    function test_zeroCappingSponsorIsSkippedButStillCountsAsALevel() public {
        address[] memory users = _chain(3);
        vm.warp(START + 500 * DAY); // users[1] claims first and caps out
        _claim(users[1]);
        assertEq(rewards.capping(users[1]), 0);
        uint256 upperBefore = rewards.generationBalance(users[0]);
        vm.warp(START + 501 * DAY);
        // users[2] claims: users[1] is skipped and users[0] still earns, if active
        _claim(users[2]);
        assertEq(rewards.generationBalance(users[1]), 0);
        assertGe(rewards.generationBalance(users[0]), upperBefore);
    }

    function test_bonusIsLimitedToRemainingCapping() public {
        address[] memory users = _chain(1);
        vm.warp(START + 299 * DAY);
        _claim(sponsor); // sponsor has 300 - 5 - 299 = 0 capping left after daily
        assertEq(rewards.capping(sponsor), 0);
        uint256 balance = rewards.generationBalance(sponsor);
        _claim(users[0]);
        assertEq(rewards.generationBalance(sponsor), balance); // nothing left to pay from
        assertGt(rewards.walletBalance(users[0]), 0);
    }

    function test_partialBonusEmptiesCapping() public {
        address[] memory users = _chain(1);
        vm.warp(START + 200 * DAY);
        _claim(sponsor); // 300 - 5 - 200 = 95 left
        vm.warp(START + 294 * DAY);
        _claim(sponsor); // 1 left
        assertEq(rewards.capping(sponsor), 1 ether);
        _claim(users[0]); // 29.4 bonus, only 1 available

        assertEq(rewards.capping(sponsor), 0);
        assertEq(rewards.generationBalance(sponsor), 1 ether);
        assertEq(rewards.activeValue(sponsor), 0);
    }

    function test_generationDoesNotCascade() public {
        address[] memory users = _chain(2);
        vm.warp(START + 10 * DAY);
        _claim(users[1]); // users[0] earns 1 and sponsor earns 1

        uint256 sponsorBefore = rewards.generationBalance(sponsor);
        vm.prank(users[0]);
        rewards.claimGeneration(); // claiming a bonus pays nobody above
        assertEq(rewards.generationBalance(sponsor), sponsorBefore);
    }

    function test_claimGenerationMovesItToTheWallet() public {
        address[] memory users = _chain(1);
        vm.warp(START + 10 * DAY);
        _claim(users[0]);
        uint256 pool = funder.rewardPool();
        uint256 wallet = rewards.walletBalance(sponsor);

        vm.prank(sponsor);
        assertEq(rewards.claimGeneration(), 1 ether);

        assertEq(rewards.walletBalance(sponsor), wallet + 1 ether);
        assertEq(rewards.generationBalance(sponsor), 0);
        assertEq(funder.rewardPool(), pool - 1 ether);

        vm.prank(sponsor);
        vm.expectRevert("NOTHING_TO_CLAIM");
        rewards.claimGeneration();
    }

    function test_earningsNeverExceedTheTierCapping() public {
        address[] memory users = _chain(3);
        vm.warp(START + 1_000 * DAY);
        for (uint256 i = 0; i < 3; i++) {
            if (rewards.pendingDaily(users[2 - i]) > 0) _claim(users[2 - i]);
        }
        assertEq(rewards.totalIncome(users[0]), 300 ether); // daily, generation and referral all inside 3x
        assertEq(rewards.capping(users[0]), 0);
    }

    /* ---------------------------- Leadership ---------------------------- */
    function _claimLeader(address user) internal returns (uint256) {
        vm.prank(user);
        return rewards.claimLeadership();
    }

    function _child(uint256 n, address up, uint256 tier) internal returns (address child) {
        child = address(uint160(0xA000 + n));
        _join(child, up);
        _activate(child, tier);
    }

    function test_fivePercentGoesToTheMonthPool() public {
        uint256 month = rewards.currentMonth();
        _activate(alice, 1);
        assertEq(rewards.monthPool(month), 5 ether);
        assertEq(rewards.leadershipPool(), 5 ether);
    }

    function test_directVolumeRanksLeaders() public {
        uint256 month = rewards.currentMonth();
        _activate(sponsor, 1);
        _activate(alice, 1);
        _child(1, sponsor, 0);
        _child(2, alice, 1); // alice 100, sponsor 150

        assertEq(rewards.monthVolume(month, sponsor), 150 ether);
        assertEq(rewards.monthVolume(month, alice), 100 ether);
        address[] memory top = rewards.monthLeaders(month);
        assertEq(top.length, 2);
        assertEq(top[0], sponsor);
        assertEq(top[1], alice);
    }

    function test_poolIsSharedByVolumeAfterCutOff() public {
        _activate(sponsor, 1); // $5
        _activate(alice, 1);   // $5, sponsor volume 100
        _child(1, alice, 1);   // $5, alice volume 100
        _child(2, alice, 1);   // $5, alice volume 200
        // pool 20: sponsor 100 of 300, alice 200 of 300
        vm.warp(FEB_01);
        assertEq(rewards.pendingLeadership(sponsor), uint256(20 ether) / 3);
        assertEq(rewards.pendingLeadership(alice), uint256(40 ether) / 3);

        uint256 wallet = rewards.walletBalance(alice);
        assertEq(_claimLeader(alice), uint256(40 ether) / 3);
        assertEq(rewards.walletBalance(alice), wallet + uint256(40 ether) / 3);
    }

    function test_cannotClaimBeforeTheFirst() public {
        _activate(sponsor, 1);
        _activate(alice, 1);
        vm.warp(FEB_01 - 1);
        vm.prank(sponsor);
        vm.expectRevert("NOTHING_TO_CLAIM");
        rewards.claimLeadership();

        vm.warp(FEB_01);
        assertEq(_claimLeader(sponsor), 10 ether); // the only leader takes the month's pool
    }

    function test_cannotClaimTwice() public {
        _activate(sponsor, 1);
        _activate(alice, 1);
        vm.warp(FEB_01);
        _claimLeader(sponsor);
        vm.prank(sponsor);
        vm.expectRevert("NOTHING_TO_CLAIM");
        rewards.claimLeadership();
    }

    function test_missedMonthsAccumulate() public {
        _activate(sponsor, 1); // $5, no qualifier yet
        _activate(alice, 0);       // $2.50
        vm.warp(FEB_01);
        _child(1, sponsor, 0);     // $2.50
        vm.warp(APR_01);
        assertEq(_claimLeader(sponsor), 10 ether);
    }

    function test_onlyTopTenShare() public {
        _activate(sponsor, 1);
        address[] memory ups = new address[](11);
        for (uint256 i = 0; i < 11; i++) {
            ups[i] = _child(100 + i, sponsor, 1);
        }
        for (uint256 i = 0; i < 10; i++) {
            _child(200 + i, ups[i], 1); // $100 volume for each of the first ten
        }
        _child(300, ups[10], 0); // only $50, so the eleventh misses out

        uint256 month = rewards.currentMonth();
        address[] memory top = rewards.monthLeaders(month);
        assertEq(top.length, 12); // sponsor plus all eleven are listed
        assertEq(top[10], ups[9]); // lost the $100 tie, so eleventh
        assertEq(top[11], ups[10]);

        vm.warp(FEB_01);
        assertEq(rewards.pendingLeadership(ups[10]), 0);
        assertEq(rewards.pendingLeadership(ups[9]), 0);
        assertGt(rewards.pendingLeadership(ups[0]), 0);

        // The ten share the whole pool, pro rata: $1,100 for the sponsor, $100 for each of the other nine.
        uint256 pool = rewards.monthPool(month);
        assertEq(rewards.pendingLeadership(sponsor), (pool * 1_100 ether) / 2_000 ether);
        assertEq(rewards.pendingLeadership(ups[0]), (pool * 100 ether) / 2_000 ether);
        uint256 shared;
        for (uint256 i = 0; i < 10; i++) shared += rewards.pendingLeadership(top[i]);
        assertApproxEqAbs(shared, pool, 10);
    }

    function test_rankingListsFiftyAndKeepsTheTopOnes() public {
        _activate(sponsor, 1);
        address[] memory ups = new address[](55);
        for (uint256 i = 0; i < 55; i++) ups[i] = _child(100 + i, sponsor, 0);
        for (uint256 i = 0; i < 55; i++) _child(1000 + i, ups[i], 0); // $50 volume each

        uint256 month = rewards.currentMonth();
        address[] memory top = rewards.monthLeaders(month);
        assertEq(top.length, rewards.LEADER_LIST());
        assertEq(top[49], ups[48]); // ties keep whoever got there first

        _child(2000, ups[54], 1); // $150 from outside the list takes second place
        top = rewards.monthLeaders(month);
        assertEq(top.length, 50);
        assertEq(top[1], ups[54]);
        assertEq(top[49], ups[47]);

        vm.warp(FEB_01);
        assertGt(rewards.pendingLeadership(ups[54]), 0);
        assertGt(rewards.pendingLeadership(ups[7]), 0); // tenth
        assertEq(rewards.pendingLeadership(ups[8]), 0); // eleventh
        assertEq(rewards.pendingLeadership(ups[47]), 0);
    }

    function test_leadershipStaysClaimableAcrossMonths() public {
        _activate(sponsor, 1);
        _activate(alice, 0); // January: $7.50 for the only leader
        vm.warp(MAR_01);
        assertEq(rewards.pendingLeadership(sponsor), 7.5 ether);
        assertEq(rewards.getUser(sponsor).pendingLeadership, 7.5 ether); // shows without any transaction
        vm.warp(START + 1_000 * DAY);
        assertEq(_claimLeader(sponsor), 7.5 ether);
        vm.prank(sponsor);
        vm.expectRevert("NOTHING_TO_CLAIM");
        rewards.claimLeadership();
    }

    function test_higherVolumeReplacesTheLastLeader() public {
        _activate(sponsor, 1);
        address[] memory ups = new address[](10);
        for (uint256 i = 0; i < 10; i++) ups[i] = _child(100 + i, sponsor, 1);
        for (uint256 i = 0; i < 9; i++) _child(200 + i, ups[i], 1); // full list: sponsor + nine at $100

        _child(300, ups[9], 1); // a $100 tie: whoever got there first keeps the place
        uint256 month = rewards.currentMonth();
        assertEq(rewards.monthLeaders(month)[9], ups[8]);
        assertEq(rewards.monthLeaders(month)[10], ups[9]);

        _child(301, ups[9], 0); // $150 moves above the $100s and pushes ups[8] out of the top ten
        address[] memory top = rewards.monthLeaders(month);
        assertEq(top.length, 11);
        assertEq(top[1], ups[9]);
        assertEq(top[10], ups[8]);

        vm.warp(FEB_01);
        assertGt(rewards.pendingLeadership(ups[9]), 0);
        assertEq(rewards.pendingLeadership(ups[8]), 0);
    }

    function test_inactiveSponsorGetsNoVolume() public {
        uint256 month = rewards.currentMonth();
        _activate(alice, 1);
        assertEq(rewards.monthVolume(month, sponsor), 0);
        assertEq(rewards.monthLeaders(month).length, 0);
    }

    function test_monthWithNoQualifierRollsForward() public {
        _activate(alice, 1); // $5, sponsor inactive
        vm.warp(FEB_01);
        uint256 month = rewards.currentMonth();
        _activate(sponsor, 1); // $5
        assertEq(rewards.monthPool(month), 10 ether);
        _child(1, sponsor, 0); // $2.50
        vm.warp(MAR_01);
        assertEq(_claimLeader(sponsor), 12.5 ether);
    }

    function test_leadershipLeavesCappingIntact() public {
        _activate(sponsor, 0);
        _activate(alice, 1);
        uint256 cappingBefore = rewards.capping(sponsor);
        uint256 free = rewards.unreservedPool();
        vm.warp(FEB_01);
        uint256 walletBefore = rewards.walletBalance(sponsor);

        assertEq(_claimLeader(sponsor), 7.5 ether);

        assertEq(rewards.capping(sponsor), cappingBefore);
        assertEq(rewards.unreservedPool(), free);
        assertEq(rewards.walletBalance(sponsor), walletBefore + 7.5 ether);
        assertEq(rewards.agentBalance(sponsor), 0);
        assertEq(rewards.leadershipPool(), 0);
    }

    function test_inactiveLeaderCanStillClaimAFinishedMonth() public {
        _activate(sponsor, 0); // 150 capping
        _activate(alice, 1);
        vm.warp(START + 400 * DAY);
        _claim(sponsor); // daily uses all of the capping
        assertEq(rewards.capping(sponsor), 0);

        uint256 wallet = rewards.walletBalance(sponsor);
        assertEq(_claimLeader(sponsor), 7.5 ether);
        assertEq(rewards.walletBalance(sponsor), wallet + 7.5 ether);
    }

    function test_claimedLeadershipCanActivateATier() public {
        _activate(sponsor, 1);
        _activate(alice, 0);
        for (uint256 i = 0; i < 10; i++) _child(i + 1, sponsor, 1);
        vm.warp(FEB_01);
        _claimLeader(sponsor);
        assertGe(rewards.walletBalance(sponsor), 50 ether);
        _setNext(sponsor, 0);
        vm.prank(sponsor);
        rewards.activate(0); // from the wallet balance, not a new deposit
        assertEq(rewards.tierCapping(sponsor, 0), 150 ether);
    }

    /* ------------------------------ Totals ----------------------------- */
    function test_totalIncomeCountsEveryEarningType() public {
        rewards.setAgent(sponsor, true);
        _activate(sponsor, 1);
        _activate(alice, 1);
        assertEq(rewards.totalIncome(sponsor), 15 ether); // 5 own agent, 5 agent from alice, 5 referral

        vm.warp(START + DAY);
        _claim(sponsor);
        assertEq(rewards.totalIncome(sponsor), 16 ether); // + $1 daily
        assertEq(rewards.totalRewardsDistributed(), 16 ether);
    }

    function test_incomeAboveCappingIsNotCounted() public {
        _activate(alice, 0);
        vm.warp(START + 500 * DAY); // 250 accrued, 150 capping
        _claim(alice);
        assertEq(rewards.totalIncome(alice), 150 ether);
    }

    function test_getUserReturnsDashboard() public {
        _activate(alice, 0);
        _activate(alice, 1);
        rewards.setAgent(alice, true);
        vm.warp(START + DAY);

        ZyqorixRewards.UserView memory v = rewards.getUser(alice);
        assertEq(v.capping, 450 ether); // the unclaimed day is settled on claim
        assertEq(v.activeValue, 150 ether);
        assertEq(v.pendingDaily, 1.5 ether);
        assertEq(v.nextClaim, 0);
        assertEq(v.activeTiers.length, 2);
        assertEq(v.activeTiers[0], 0);
        assertTrue(v.isAgent);

        _claim(alice);
        assertEq(rewards.getUser(alice).nextClaim, START + 2 * DAY);
        assertEq(rewards.getUser(alice).walletBalance, 1.5 ether);
    }

    /* -------------------------- Admin + wiring -------------------------- */
    function test_adminGates() public {
        vm.startPrank(alice);
        vm.expectRevert("NOT_AUTH");
        rewards.setAgent(alice, true);
        vm.expectRevert("NOT_AUTH");
        rewards.syncActiveDirects(alice, 5);
        vm.expectRevert("NOT_AUTH");
        rewards.setDistribution(5_000, 1_000, 500, 1_000, 500, 500);
        vm.expectRevert("NOT_AUTH");
        rewards.setAgentWalkLimit(10);
        vm.expectRevert("NOT_GATEWAY");
        rewards.creditDeposit(alice, 1);
        vm.expectRevert("NOT_GATEWAY");
        rewards.debitWallet(alice, 1);
        vm.expectRevert("NOT_GATEWAY");
        rewards.debitAgent(alice, 1);
        vm.stopPrank();

        vm.expectRevert("BAD_DISTRIBUTION");
        rewards.setDistribution(6_000, 1_000, 500, 2_500, 500, 500);
        vm.expectRevert("BAD_DISTRIBUTION");
        rewards.setDistribution(5_000, 1_000, 1_000, 500, 500, 500);
        vm.expectRevert("BAD_LIMIT");
        rewards.setAgentWalkLimit(0);
        vm.expectRevert("NOT_REGISTERED");
        rewards.setAgent(bob, true);
    }

    function test_syncActiveDirectsCorrectsTheCount() public {
        vm.prank(hub);
        rewards.syncActiveDirects(sponsor, 7);
        assertEq(rewards.activeDirects(sponsor), 7);
    }

    function testFuzz_funderAlwaysCoversRecordedBalances(uint256 seed) public {
        address[] memory users = new address[](6);
        users[0] = sponsor;
        users[1] = alice;
        for (uint256 i = 2; i < 6; i++) {
            users[i] = address(uint160(0x4000 + i));
            _join(users[i], users[i - 1]);
        }
        uint256 at = START;
        for (uint256 step = 0; step < 40; step++) {
            uint256 x = uint256(keccak256(abi.encode(seed, step)));
            address u = users[x % 6];
            uint256 tier = (x >> 8) % 2;
            uint256 op = (x >> 16) % 3;
            at += ((x >> 24) % 3) * DAY;
            vm.warp(at);
            if (op == 0 && rewards.tierCapping(u, tier) == 0) {
                _activate(u, tier);
            } else if (op == 1) {
                _reserve((x >> 32) % 20 ether);
            } else if (block.timestamp >= rewards.lastClaim(u) + DAY && rewards.pendingDaily(u) > 0) {
                _claim(u);
            }

            uint256 owed = rewards.leadershipPool() + funder.rewardPool();
            for (uint256 i = 0; i < 6; i++) owed += rewards.walletBalance(users[i]) + rewards.agentBalance(users[i]);
            assertGe(usdt.balanceOf(address(funder)), owed);
            // Every daily reward still owed is already in the pool.
            uint256 unclaimed;
            for (uint256 i = 0; i < 6; i++) unclaimed += rewards.unclaimedDaily(users[i]);
            assertEq(rewards.unreservedPool() + rewards.totalCapping() + unclaimed + rewards.totalGeneration(), funder.rewardPool());
        }
    }
}
