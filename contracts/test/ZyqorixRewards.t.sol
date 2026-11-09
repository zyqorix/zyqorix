// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test, stdStorage, StdStorage} from "forge-std/Test.sol";
import {ZyqorixAccounts} from "../accounts.sol";
import {ZyqorixFunder} from "../funder.sol";
import {ZyqorixGateway} from "../gateway.sol";
import {ZyqorixRewards} from "../rewards.sol";
import {ZQRMock} from "../zqrmock.sol";
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

/// @dev 1 USDT = 2 ZQR by default (`zqrPerUsdt`). Takes the activation's liquidity share like addLiquidityUSDT.
contract MockLiquidity {
    address public USDT;
    address public TOKEN;
    bool public fail;
    bool public priceFail;
    uint256 public zqrPerUsdt = 2;

    constructor(address usdt, address token) { USDT = usdt; TOKEN = token; }
    function setFail(bool v) external { fail = v; }
    function setPriceFail(bool v) external { priceFail = v; }
    function setZqrPerUsdt(uint256 v) external { zqrPerUsdt = v; }
    function convertToken(address, uint256 amountIn) external view returns (uint256) {
        require(!priceFail, "TwapPriceFailed");
        return amountIn * zqrPerUsdt;
    }

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
    /// @dev USDT's BSC mainnet address, hardcoded in funder, gateway, liquidity and the exchanger.
    address constant USDT_ADDR = 0x55d398326f99059fF775485246999027B3197955;
    address constant ZQR_ADDR = 0x43ADE7aE5E14e6dadD0f6967a0aDEADe56095e70;
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
    ZQRMock zqr;
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
        // USDT's mainnet address is hardcoded in the contracts: etch the mock there.
        vm.etch(USDT_ADDR, type(MockUsdt).runtimeCode);
        usdt = MockUsdt(USDT_ADDR);
        accounts = new ZyqorixAccounts();
        accounts.addAdmin(hub);
        funder = new ZyqorixFunder(address(accounts));
        gateway = new ZyqorixGateway(address(accounts), address(funder));
        gateway.setMinDeposit(0); // these tests size deposits freely; ZyqorixFlow tests the minimum
        funder.setGateway(address(gateway));
        funder.setTradingWallet(trading);
        // ZQR's mainnet address is hardcoded in vesting.sol: etch the mock there and mint the full supply.
        vm.etch(ZQR_ADDR, type(ZQRMock).runtimeCode);
        zqr = ZQRMock(ZQR_ADDR);
        zqr.mint(address(this), zqr.MAX_SUPPLY());
        vesting = new ZyqorixVesting(address(accounts), 30 days);
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

    /// @dev Send `profit` from the trading wallet, so the reward pool receives exactly `profit`.
    function _reserve(uint256 profit) internal {
        usdt.mint(trading, profit);
        vm.startPrank(trading);
        usdt.approve(address(funder), profit);
        funder.fundRewards(profit);
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

    function test_firstActivationKeepsTheFirstTime() public {
        assertEq(rewards.firstActivation(alice), 0);
        _activate(alice, 0); // at START (warp targets are constants: see memory foundry-blocktimestamp-warp-optimizer)
        assertEq(rewards.firstActivation(alice), START);
        vm.warp(START + 10 * DAY);
        _activate(alice, 1);
        assertEq(rewards.firstActivation(alice), START);
    }

    function test_distributionOfA100Activation() public {
        _activate(sponsor, 1); // active sponsor, no referral paid upward because root is inactive
        uint256 funderBefore = usdt.balanceOf(address(funder));
        uint256 tradingBefore = usdt.balanceOf(trading);
        uint256 lpBefore = usdt.balanceOf(address(lp));
        rewards.setAgent(sponsor, true);

        _activate(alice, 1);

        assertEq(usdt.balanceOf(address(lp)) - lpBefore, 20 ether);
        assertEq(usdt.balanceOf(trading) - tradingBefore, 60 ether);
        assertEq(usdt.balanceOf(address(funder)) - funderBefore, 20 ether); // 5 referral + 5 unpaid, 5 agent, 5 leadership
        assertEq(rewards.walletBalance(sponsor), 5 ether);
        assertEq(rewards.agentBalance(sponsor), 5 ether);
        assertEq(rewards.leadershipPool(), 10 ether); // both activations
        assertEq(funder.tradingCapitalOut(), 120 ether);
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
        ZyqorixVesting next = new ZyqorixVesting(address(accounts), 30 days);
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
        assertEq(usdt.balanceOf(address(funder)), BASE + 40 ether); // everything except trading
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

    /* ------------------------------ Pricing ---------------------------- */
    function test_priceDefaults() public view {
        assertEq(rewards.lastPrice(), 1e15); // 0.001 USDT per ZQR
        assertEq(rewards.floorPrice(), 1e15);
        assertEq(rewards.lastPriceAt(), 0);
    }

    function test_liveTwapReadBecomesLastPrice() public {
        _fund(alice, 50 ether);
        vm.expectEmit(address(rewards));
        emit ZyqorixRewards.LastPriceUpdated(0.5 ether); // 2 ZQR per USDT = 0.5 USDT per ZQR
        vm.prank(alice);
        rewards.activate(0);
        assertEq(rewards.lastPrice(), 0.5 ether);
        assertEq(rewards.lastPriceAt(), block.timestamp);
        assertEq(vesting.getPosition(alice, 0).amount, 100 ether);
    }

    function test_unreadableTwapUsesLastPrice() public {
        rewards.setLastPrice(0.25 ether);
        lp.setPriceFail(true);
        _fund(alice, 50 ether);
        vm.expectEmit(address(rewards));
        emit ZyqorixRewards.PriceFallbackUsed(alice, 0.25 ether);
        vm.prank(alice);
        rewards.activate(0); // never reverts on price
        assertEq(vesting.getPosition(alice, 0).amount, 200 ether); // $50 / 0.25
        assertEq(rewards.lastPrice(), 0.25 ether); // a failed read leaves it alone
    }

    function test_seededLastPriceCoversALaunchWithoutAnOracle() public {
        zqr.transfer(address(vesting), 100_000 ether);
        lp.setPriceFail(true);
        _activate(alice, 0);
        assertEq(vesting.getPosition(alice, 0).amount, 50_000 ether); // $50 at the seeded 0.001
    }

    function test_pushedDownTwapIsFloored() public {
        zqr.transfer(address(vesting), 10_000_000 ether);
        lp.setZqrPerUsdt(100_000); // someone dumped ZQR: 0.00001 USDT per ZQR
        _fund(alice, 50 ether);
        vm.expectEmit(address(rewards));
        emit ZyqorixRewards.PriceFloored(alice, 1e13, 1e15);
        vm.prank(alice);
        rewards.activate(0);
        assertEq(vesting.getPosition(alice, 0).amount, 50_000 ether); // $50 / 0.001, not 5,000,000
        assertEq(rewards.lastPrice(), 1e13); // the record keeps the real read; the floor still applies
    }

    function test_lowLastPriceIsFloored() public {
        zqr.transfer(address(vesting), 10_000_000 ether);
        rewards.setLastPrice(1e12);
        lp.setPriceFail(true);
        _activate(alice, 0);
        assertEq(vesting.getPosition(alice, 0).amount, 50_000 ether);
    }

    function test_lowerFloorFollowsARealDrop() public {
        zqr.transfer(address(vesting), 10_000_000 ether);
        rewards.setFloorPrice(5e14); // 0.0005
        lp.setZqrPerUsdt(1_500); // 0.000666...
        _activate(alice, 0);
        assertEq(vesting.getPosition(alice, 0).amount, 75_000 ether); // the live TWAP, above the new floor
    }

    function test_priceSettersGates() public {
        vm.prank(alice);
        vm.expectRevert("NOT_AUTH");
        rewards.setLastPrice(1e15);
        vm.prank(alice);
        vm.expectRevert("NOT_AUTH");
        rewards.setFloorPrice(1e15);
        vm.expectRevert("BAD_PRICE");
        rewards.setLastPrice(0);
        vm.expectRevert("BAD_PRICE");
        rewards.setFloorPrice(0);
        vm.prank(hub);
        rewards.setFloorPrice(2e15);
        assertEq(rewards.floorPrice(), 2e15);
        vm.warp(START + 5);
        vm.prank(hub);
        rewards.setLastPrice(3e15);
        assertEq(rewards.lastPrice(), 3e15);
        assertEq(rewards.lastPriceAt(), START + 5);
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
        _activate(alice, 0); // the counters run from the first activation, at START
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

    function test_dayCountersNeedAnActivation() public {
        // Registered at START but never activated: no amount of time opens the later pairs.
        vm.warp(START + 1_000 * DAY);
        assertFalse(rewards.isTierUnlocked(alice, 2));
        assertFalse(rewards.isTierUnlocked(alice, 4));
    }

    function test_dayCountersRunFromFirstActivationNotRegistration() public {
        // alice registered at START and first activates on day 100: the $200 pair opens on day 160, not day 60.
        vm.warp(START + 100 * DAY);
        _activate(alice, 0);
        assertEq(rewards.firstActivation(alice), START + 100 * DAY);
        assertFalse(rewards.isTierUnlocked(alice, 2));
        vm.warp(START + 160 * DAY - 1);
        assertFalse(rewards.isTierUnlocked(alice, 2));
        vm.warp(START + 160 * DAY);
        assertTrue(rewards.isTierUnlocked(alice, 2));
        assertFalse(rewards.isTierUnlocked(alice, 4));
        // A later activation doesn't move the start.
        _activate(alice, 1);
        assertEq(rewards.firstActivation(alice), START + 100 * DAY);
        vm.warp(START + 220 * DAY);
        assertTrue(rewards.isTierUnlocked(alice, 4));
    }

    function test_onlyOneCappedTierDoesNotUnlock() public {
        _activate(alice, 0);
        vm.warp(START + 59 * DAY); // $0.50 a day can't reach $150 by day 59
        assertFalse(rewards.isTierUnlocked(alice, 2));
    }

    /* ----------------------------- Referral ---------------------------- */
    function test_referralIs5PercentBelowSixActiveDirects() public {
        _activate(sponsor, 1);
        _activate(alice, 1);
        assertEq(rewards.activeDirects(sponsor), 1);
        assertEq(rewards.walletBalance(sponsor), 5 ether);
    }

    /// @dev Owner rule: directs 1 to 5 pay 5%, the 6th active direct and later pay 10%.
    function test_referralIs10PercentFromTheSixthActiveDirect() public {
        _activate(sponsor, 1);
        for (uint256 i = 0; i < 4; i++) {
            address child = address(uint160(0x7000 + i));
            _join(child, sponsor);
            _activate(child, 0); // 5% of 50 each
        }
        assertEq(rewards.activeDirects(sponsor), 4);
        assertEq(rewards.walletBalance(sponsor), 10 ether);

        _activate(alice, 1); // the fifth active direct still pays 5%
        assertEq(rewards.activeDirects(sponsor), 5);
        assertEq(rewards.walletBalance(sponsor), 15 ether); // + 5% of 100

        address sixth = address(uint160(0x7100));
        _join(sixth, sponsor);
        _activate(sixth, 1); // the sixth pays 10%
        assertEq(rewards.activeDirects(sponsor), 6);
        assertEq(rewards.walletBalance(sponsor), 25 ether); // + 10% of 100
    }

    function test_corrected5ActiveDirectsMakesTheNextNewDirectPay10Percent() public {
        _activate(sponsor, 1);
        rewards.syncActiveDirects(sponsor, 5);
        _activate(alice, 1); // counted as the sixth
        assertEq(rewards.activeDirects(sponsor), 6);
        assertEq(rewards.walletBalance(sponsor), 10 ether);
    }

    function test_existingDirectActivatingAgainUsesTheCurrentCount() public {
        _activate(sponsor, 1);
        for (uint256 i = 0; i < 4; i++) {
            address child = address(uint160(0x7200 + i));
            _join(child, sponsor);
            _activate(child, 0);
        }
        _activate(alice, 0); // fifth active direct: 2.50
        assertEq(rewards.walletBalance(sponsor), 12.5 ether);

        _activate(alice, 1); // alice is already counted, still 5 active: 5% of 100
        assertEq(rewards.activeDirects(sponsor), 5);
        assertEq(rewards.walletBalance(sponsor), 17.5 ether);

        address sixth = address(uint160(0x7300));
        _join(sixth, sponsor);
        _activate(sixth, 0); // sixth active direct: 10% of 50
        _activate(address(uint160(0x7200)), 1); // 6 active now, an existing direct's next tier: 10% of 100
        assertEq(rewards.walletBalance(sponsor), 32.5 ether);
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

    function test_firstAgentUpTheTreeEarns() public {
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

    function test_inactiveAgentStillEarns() public {
        rewards.setAgent(owner, false);
        rewards.setAgent(alice, true); // alice has no capping when bob activates
        rewards.setAgent(sponsor, true);
        _activate(sponsor, 0);
        _join(bob, alice);
        _activate(bob, 1);
        assertEq(rewards.capping(alice), 0);
        assertEq(rewards.agentBalance(alice), 5 ether); // agent rewards need no activation
        assertEq(rewards.agentBalance(sponsor), 2.5 ether); // only its own activation
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
    function test_allTradingMoneyEntersThePool() public {
        uint256 outBefore = funder.tradingCapitalOut();
        _activate(alice, 1); // 60 out for trading, never repaid
        uint256 pool = funder.rewardPool();
        usdt.mint(trading, 9 ether);
        vm.startPrank(trading);
        usdt.approve(address(funder), 9 ether);
        funder.fundRewards(9 ether);
        vm.stopPrank();
        assertEq(funder.rewardPool(), pool + 9 ether);
        assertEq(funder.tradingCapitalOut() - outBefore, 60 ether); // only counted
    }

    function test_plainTransferIsNotRewardPool() public {
        _activate(alice, 1);
        uint256 pool = funder.rewardPool();
        usdt.mint(address(funder), 1_000 ether);
        assertEq(funder.rewardPool(), pool);
    }

    function test_onlyFunderCanAddProfit() public {
        vm.expectRevert("NOT_FUNDER");
        rewards.notifyProfit(1 ether);
    }

    function test_activationFlowsAreRewardsOnly() public {
        vm.prank(alice); // the owner may call sendToTrading (below); anyone else may not
        vm.expectRevert("NOT_REWARDS");
        funder.sendToTrading(1 ether);
        vm.expectRevert("NOT_REWARDS");
        funder.sendToLiquidity(address(lp), 1 ether, 300);
        vm.expectRevert("NOT_REWARDS");
        funder.drawRewardPool(1 ether);
    }

    /// Owner 2026-11-08: the owner may send funder USDT to the trading wallet directly. It is counted as
    /// capital out like an activation's trading share, and nobody else can call it.
    function test_ownerCanSendToTrading() public {
        _activate(alice, 1);
        uint256 outBefore = funder.tradingCapitalOut();
        uint256 held = usdt.balanceOf(address(funder));
        uint256 walletBefore = usdt.balanceOf(trading);
        funder.sendToTrading(10 ether); // this test contract is the accounts owner
        assertEq(funder.tradingCapitalOut() - outBefore, 10 ether);
        assertEq(usdt.balanceOf(address(funder)), held - 10 ether);
        assertEq(usdt.balanceOf(trading) - walletBefore, 10 ether);
    }

    /* --------------------------- Daily rewards -------------------------- */
    function test_activationNeedsNoRewardPool() public {
        _deploy(); // an empty reward pool
        _fund(alice, 100 ether);
        _setNext(alice, 1);
        vm.prank(alice);
        rewards.activate(1);
        assertEq(rewards.totalCapping(), 300 ether);
        assertEq(funder.rewardPool(), 0);
    }

    function test_oneDayPaysExactlyOnePercent() public {
        _activate(alice, 1);
        vm.warp(START + DAY);
        assertEq(_claim(alice), 1 ether); // $100 tier
        assertEq(rewards.walletBalance(alice), 1 ether);
        assertEq(rewards.rewardCredit(alice), 1 ether);
        assertEq(funder.rewardPool(), BASE); // drawn only when it leaves the wallet
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

    function test_referralUsesCappingAndIsNotRewardCredit() public {
        _activate(sponsor, 1);
        _activate(alice, 1); // sponsor uses 5 capping
        assertEq(rewards.totalCapping(), 300 ether + 295 ether);
        assertEq(rewards.walletBalance(sponsor), 5 ether);
        assertEq(rewards.rewardCredit(sponsor), 0);
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
        assertEq(rewards.rewardCredit(alice), 0);
        assertEq(funder.rewardPool(), BASE - 18 ether); // the gross was drawn from the pool, and the 2 fee booked back (no LP position)
    }

    /* ---------------------- Reward pool at withdrawal ------------------- */
    /// @dev Alice holds 20 of deposit and 20 of claimed daily (reward credit), with an empty reward pool.
    function _creditWithEmptyPool() internal {
        _deploy(); // an empty reward pool
        _activate(alice, 0);
        _fund(alice, 20 ether);
        vm.warp(START + 40 * DAY);
        assertEq(_claim(alice), 20 ether); // claims never revert on the pool
        vm.warp(START + 41 * DAY);
        assertEq(rewards.walletBalance(alice), 40 ether);
        assertEq(rewards.rewardCredit(alice), 20 ether);
        assertEq(funder.rewardPool(), 0);
    }

    function test_withdrawalOfFreeBalanceNeedsNoPool() public {
        _creditWithEmptyPool();
        assertEq(rewards.withdrawable(alice), 20 ether);
        vm.prank(alice);
        gateway.withdraw(20 ether);
        assertEq(rewards.walletBalance(alice), 20 ether);
        assertEq(rewards.rewardCredit(alice), 20 ether); // the deposit part went first
    }

    function test_withdrawalOfRewardCreditWaitsForThePool() public {
        _creditWithEmptyPool();
        usdt.mint(address(funder), 10 ether); // enough USDT in the funder, so only the pool can refuse
        uint256 held = usdt.balanceOf(address(funder));
        uint256 cooldown = gateway.coolDown(alice);
        vm.prank(alice);
        vm.expectRevert("INSUFFICIENT_REWARD_POOL");
        gateway.withdraw(40 ether);
        // Nothing moved, and the cooldown didn't restart.
        assertEq(rewards.walletBalance(alice), 40 ether);
        assertEq(rewards.rewardCredit(alice), 20 ether);
        assertEq(usdt.balanceOf(address(funder)), held);
        assertEq(gateway.coolDown(alice), cooldown);

        _reserve(15 ether);
        assertEq(rewards.withdrawable(alice), 35 ether);
        vm.prank(alice);
        vm.expectRevert("INSUFFICIENT_REWARD_POOL");
        gateway.withdraw(40 ether);

        _reserve(5 ether);
        assertEq(rewards.withdrawable(alice), 40 ether);
        vm.prank(alice);
        gateway.withdraw(40 ether);
        assertEq(rewards.walletBalance(alice), 0);
        assertEq(rewards.rewardCredit(alice), 0);
        assertEq(funder.rewardPool(), 4 ether); // exactly the credit part was drawn; the 4 fee was booked back
        assertEq(rewards.totalRewardCredit(), 0);
    }

    function test_activationFromRewardCreditDrawsThePool() public {
        _deploy();
        _activate(alice, 1); // 300 capping
        vm.warp(START + 50 * DAY);
        assertEq(_claim(alice), 50 ether);
        _setNext(alice, 0);
        vm.prank(alice);
        vm.expectRevert("INSUFFICIENT_REWARD_POOL");
        rewards.activate(0);

        _reserve(50 ether);
        vm.prank(alice);
        rewards.activate(0);
        assertEq(rewards.rewardCredit(alice), 0);
        assertEq(funder.rewardPool(), 10 ether); // only the 40 of trading and liquidity share is drawn
        assertEq(rewards.tierCapping(alice, 0), 150 ether);
    }

    function test_totalsFollowEveryBalance() public {
        rewards.setAgent(sponsor, true);
        _activate(sponsor, 1);
        _activate(alice, 1);
        vm.warp(START + 10 * DAY);
        _claim(alice);
        assertEq(rewards.totalWalletBalance(), rewards.walletBalance(sponsor) + rewards.walletBalance(alice));
        assertEq(rewards.totalRewardCredit(), rewards.rewardCredit(sponsor) + rewards.rewardCredit(alice));
        assertEq(rewards.totalAgentBalance(), rewards.agentBalance(sponsor));
        assertEq(rewards.totalAgentBalance(), 10 ether);
        vm.prank(sponsor);
        gateway.withdrawAgent(10 ether);
        assertEq(rewards.totalAgentBalance(), 0);
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

    /* ---------------------- Zero-capping safety net --------------------- */
    /// @dev The sponsor ends at zero capping with 90 of uncollected daily and a 5 generation bonus: a downline's
    ///      claim settles the sponsor's 90 days, then the 29 bonus takes the last 5 of capping.
    function _sponsorUsedUpWithRewardsLeft() internal returns (address[] memory users) {
        users = _chain(1);
        vm.warp(START + 200 * DAY);
        _claim(sponsor); // 300 - 5 - 200 = 95 left
        vm.warp(START + 290 * DAY);
        _claim(users[0]);
        assertEq(rewards.capping(sponsor), 0);
        assertEq(rewards.unclaimedDaily(sponsor), 90 ether);
        assertEq(rewards.generationBalance(sponsor), 5 ether);
    }

    function test_zeroCappingKeepsOwedDailyAndGeneration() public {
        _sponsorUsedUpWithRewardsLeft();
        assertEq(rewards.pendingDaily(sponsor), 90 ether); // still shown as collectable
        uint256 wallet = rewards.walletBalance(sponsor);
        uint256 credit = rewards.rewardCredit(sponsor);
        vm.warp(START + 291 * DAY);

        assertEq(_claim(sponsor), 90 ether);
        vm.prank(sponsor);
        assertEq(rewards.claimGeneration(), 5 ether);

        assertEq(rewards.unclaimedDaily(sponsor), 0);
        assertEq(rewards.generationBalance(sponsor), 0);
        assertEq(rewards.walletBalance(sponsor), wallet + 95 ether);
        assertEq(rewards.rewardCredit(sponsor), credit + 95 ether);
    }

    function test_nothingLeftAtZeroCappingReverts() public {
        _sponsorUsedUpWithRewardsLeft();
        _claim(sponsor);
        vm.startPrank(sponsor);
        rewards.claimGeneration();
        vm.warp(START + 400 * DAY);
        vm.expectRevert("NOTHING_TO_CLAIM");
        rewards.claimDaily();
        vm.expectRevert("NOTHING_TO_CLAIM");
        rewards.claimGeneration();
        vm.stopPrank();
    }

    function test_theClaimThatUsesUpCappingStillPaysWhatItCovers() public {
        _chain(1);
        vm.warp(START + 200 * DAY);
        _claim(sponsor); // 95 left
        vm.warp(START + 300 * DAY); // 100 days earned, only 95 covered
        uint256 wallet = rewards.walletBalance(sponsor);
        assertEq(_claim(sponsor), 95 ether);
        assertEq(rewards.walletBalance(sponsor), wallet + 95 ether);
        assertEq(rewards.capping(sponsor), 0);
    }

    function test_reactivationKeepsOwedRewards() public {
        _sponsorUsedUpWithRewardsLeft();
        _fund(sponsor, rewards.tierPrice(2));
        _setNext(sponsor, 2);
        vm.prank(sponsor);
        rewards.activate(2);

        assertEq(rewards.unclaimedDaily(sponsor), 90 ether);
        assertEq(rewards.generationBalance(sponsor), 5 ether);
        assertEq(rewards.capping(sponsor), 600 ether);
        assertEq(rewards.pendingDaily(sponsor), 90 ether);
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
        assertEq(rewards.rewardCredit(sponsor), 1 ether);
        assertEq(funder.rewardPool(), pool); // drawn when it leaves the wallet

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

    /// @dev A direct who joined last month and opens a higher tier this month counts as this month's volume.
    function test_directsHigherTierNextMonthCountsForThatMonth() public {
        uint256 jan = rewards.currentMonth();
        _activate(sponsor, 1); // $5 into January's pool
        _activate(alice, 0);   // $2.50, sponsor January volume 50

        vm.warp(FEB_01);
        uint256 feb = rewards.currentMonth();
        _activate(alice, 1);   // $5 into February's pool, sponsor February volume 100
        assertEq(rewards.monthVolume(jan, sponsor), 50 ether);
        assertEq(rewards.monthVolume(feb, sponsor), 100 ether);
        assertEq(rewards.monthLeaders(feb)[0], sponsor);
        assertEq(rewards.pendingLeadership(sponsor), 7.5 ether); // only January has closed

        vm.warp(MAR_01);
        assertEq(rewards.pendingLeadership(sponsor), 12.5 ether); // January 7.50 + February 5
        assertEq(_claimLeader(sponsor), 12.5 ether);
    }

    /// @dev Volume needs capping at the moment of the activation: a capped-out sponsor gets none that month.
    function test_cappedOutSponsorGetsNoVolumeFromAHigherTier() public {
        _activate(sponsor, 0); // 150 capping, caps after 300 days
        _activate(alice, 0);
        vm.warp(START + 400 * DAY);
        uint256 month = rewards.currentMonth();
        _activate(alice, 1);
        assertEq(rewards.capping(sponsor), 0);
        assertEq(rewards.monthVolume(month, sponsor), 0);
        assertEq(rewards.monthLeaders(month).length, 0);
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
        vm.warp(FEB_01);
        uint256 walletBefore = rewards.walletBalance(sponsor);

        assertEq(_claimLeader(sponsor), 7.5 ether);

        assertEq(rewards.capping(sponsor), cappingBefore);
        assertEq(rewards.rewardCredit(sponsor), 0); // leadership is activation money, not pool money
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

    /* --------------- Activation from the whole wallet (owner 2026-11-08) --------------- */
    /// @dev The funder's USDT covers everything outside reward credit, plus the reward pool.
    function _assertSolvent() internal view {
        uint256 cash = (rewards.totalWalletBalance() - rewards.totalRewardCredit())
            + (rewards.totalAgentBalance() - rewards.totalAgentCredit())
            + (rewards.leadershipPool() - rewards.leadershipCredit());
        assertGe(usdt.balanceOf(address(funder)), cash + funder.rewardPool());
    }

    /// @dev `user` holds `days_` USDT of daily reward credit from a $100 tier, and the reward pool is empty.
    function _creditFromTier1(address user, uint256 days_) internal {
        _activate(user, 1);
        vm.warp(START + days_ * DAY);
        assertEq(_claim(user), days_ * 1 ether);
        assertEq(rewards.rewardCredit(user), days_ * 1 ether);
    }

    function test_depositActivatesWithAnEmptyPoolAndStuckCredit() public {
        _deploy(); // an empty reward pool
        _activate(sponsor, 1);
        _creditFromTier1(alice, 100);
        assertEq(funder.rewardPool(), 0);
        _fund(alice, 200 ether);
        _setNext(alice, 2);
        assertEq(rewards.activationPoolNeed(alice, 2), 0);
        vm.prank(alice);
        rewards.activate(2); // the deposit pays it all; the 100 of credit waits
        assertEq(rewards.rewardCredit(alice), 100 ether);
        assertEq(rewards.walletBalance(alice), 100 ether);
        assertEq(funder.rewardPool(), 0);
        _assertSolvent();
    }

    function test_creditActivationNeedsEightyPercentOfThePool() public {
        _deploy(); // an empty reward pool
        _activate(sponsor, 1);
        _creditFromTier1(alice, 50);
        _setNext(alice, 0);
        assertEq(rewards.activationPoolNeed(alice, 0), 40 ether);
        _reserve(40 ether - 1);
        vm.prank(alice);
        vm.expectRevert("INSUFFICIENT_REWARD_POOL");
        rewards.activate(0);
        assertEq(rewards.walletBalance(alice), 50 ether);
        assertEq(rewards.rewardCredit(alice), 50 ether);
        assertEq(rewards.nextTier(alice), 0);

        _reserve(1);
        uint256 tradingBefore = usdt.balanceOf(trading);
        uint256 lpBefore = usdt.balanceOf(address(lp));
        vm.prank(alice);
        rewards.activate(0);
        assertEq(funder.rewardPool(), 0); // 40 drawn: the trading and liquidity shares
        assertEq(usdt.balanceOf(trading) - tradingBefore, 30 ether);
        assertEq(usdt.balanceOf(address(lp)) - lpBefore, 10 ether);
        assertEq(rewards.walletBalance(alice), 0);
        assertEq(rewards.rewardCredit(alice), 0);
        assertEq(rewards.tierCapping(alice, 0), 150 ether);
        _assertSolvent();
    }

    function test_mixedActivationDrawsOnlyTheCreditPart() public {
        _deploy(); // an empty reward pool
        _activate(sponsor, 1);
        _creditFromTier1(alice, 60); // day 60: the $200 tier is open
        _fund(alice, 140 ether); // 140 of deposit + 60 of credit pays the $200 tier
        _setNext(alice, 2);
        assertEq(rewards.activationPoolNeed(alice, 2), 48 ether);
        vm.prank(alice);
        vm.expectRevert("INSUFFICIENT_REWARD_POOL");
        rewards.activate(2);

        _reserve(48 ether);
        vm.prank(alice);
        rewards.activate(2);
        assertEq(funder.rewardPool(), 0);
        assertEq(rewards.rewardCredit(alice), 0);
        assertEq(rewards.walletBalance(alice), 0);
        _assertSolvent();
    }

    function test_referralFromACreditActivationIsRewardCredit() public {
        _deploy(); // an empty reward pool
        _activate(sponsor, 1);
        _creditFromTier1(alice, 50); // the sponsor's 5 of referral is deposit money
        assertEq(rewards.walletBalance(sponsor), 5 ether);
        _setNext(alice, 0);
        _reserve(40 ether);
        vm.prank(alice);
        rewards.activate(0);
        assertEq(rewards.walletBalance(sponsor), 7.5 ether);
        assertEq(rewards.rewardCredit(sponsor), 2.5 ether); // 5% of a credit-paid $50
        assertEq(rewards.withdrawable(sponsor), 5 ether); // the pool is empty again
        _reserve(2.5 ether);
        assertEq(rewards.withdrawable(sponsor), 7.5 ether);
        _assertSolvent();
    }

    function test_agentShareFromACreditActivationWaitsForThePool() public {
        _deploy(); // an empty reward pool
        rewards.setAgent(sponsor, true);
        _activate(sponsor, 1); // 5 to the sponsor as agent
        _creditFromTier1(alice, 100); // 5 more
        _setNext(alice, 1);
        _reserve(80 ether);
        vm.prank(alice);
        rewards.activate(1); // all from credit: its 5 of agent share is agent credit
        assertEq(rewards.agentBalance(sponsor), 15 ether);
        assertEq(rewards.agentCredit(sponsor), 5 ether);
        assertEq(rewards.agentWithdrawable(sponsor), 10 ether);
        assertEq(funder.rewardPool(), 0);
        _assertSolvent();

        vm.prank(sponsor);
        vm.expectRevert("INSUFFICIENT_REWARD_POOL");
        gateway.withdrawAgent(15 ether);
        vm.prank(sponsor);
        gateway.withdrawAgent(10 ether); // the deposit-paid part needs no pool
        assertEq(rewards.agentCredit(sponsor), 5 ether);

        vm.warp(block.timestamp + DAY + 1);
        vm.prank(sponsor);
        vm.expectRevert("INSUFFICIENT_REWARD_POOL");
        gateway.withdrawAgent(5 ether);
        _reserve(5 ether);
        vm.prank(sponsor);
        gateway.withdrawAgent(5 ether);
        assertEq(rewards.agentBalance(sponsor), 0);
        assertEq(rewards.agentCredit(sponsor), 0);
        assertEq(rewards.totalAgentCredit(), 0);
        assertEq(funder.rewardPool(), 0);
        _assertSolvent();
    }

    function test_leadershipFromACreditActivationIsRewardCredit() public {
        _deploy(); // an empty reward pool
        _activate(sponsor, 1);
        _creditFromTier1(alice, 50); // 2027-03-06: March
        _setNext(alice, 0);
        _reserve(40 ether);
        vm.prank(alice);
        rewards.activate(0); // 2.50 of credit into March's pool
        _join(bob, sponsor);
        _activate(bob, 0); // 2.50 of deposit money into March's pool
        uint256 mar = rewards.currentMonth();
        assertEq(rewards.monthPool(mar), 5 ether);
        assertEq(rewards.monthPoolCredit(mar), 2.5 ether);

        vm.warp(MAR_01 + 5 * DAY); // still March: January's pool (10, all deposits) is claimable
        uint256 creditBefore = rewards.rewardCredit(sponsor);
        assertEq(_claimLeader(sponsor), 10 ether);
        assertEq(rewards.rewardCredit(sponsor), creditBefore);

        vm.warp(APR_01);
        assertEq(_claimLeader(sponsor), 5 ether);
        assertEq(rewards.rewardCredit(sponsor), creditBefore + 2.5 ether);
        assertEq(rewards.leadershipPool(), 0);
        assertEq(rewards.leadershipCredit(), 0);
        _assertSolvent();
    }

    /// @dev Audit 2026-11-08 M-1: a liquidity share that stays in the funder is not drawn from the pool.
    function test_failedLiquiditySendKeepsItsShareInThePool() public {
        _deploy(); // an empty reward pool
        _activate(sponsor, 1);
        _creditFromTier1(alice, 50);
        _setNext(alice, 0);
        _reserve(40 ether);
        lp.setFail(true);
        vm.prank(alice);
        rewards.activate(0);
        assertEq(funder.rewardPool(), 10 ether); // only the 30 of trading share left
        assertEq(rewards.rewardCredit(alice), 0);
        _assertSolvent();
    }

    /// @dev Audit 2026-11-08 L-1: uneven pro-rata splits round credit up, so leadership credit never exceeds
    ///      the leadership pool and no rounding dust turns into cash.
    function test_unevenLeadershipSplitsNeverOverpayCash() public {
        _deploy(); // an empty reward pool
        address[3] memory leaders = [makeAddr("l1"), makeAddr("l2"), makeAddr("l3")];
        _activate(sponsor, 1);
        for (uint256 i = 0; i < 3; i++) {
            _join(leaders[i], sponsor);
            _activate(leaders[i], 1);
        }
        _creditFromTier1(alice, 50); // 2027-03-06
        _reserve(1_000 ether);
        // Three leaders with uneven March volume (1, 2 and 4 credit-paid $50 children, with a 1-wei deposit mix).
        uint256 n;
        for (uint256 i = 0; i < 3; i++) {
            for (uint256 k = 0; k < (1 << i); k++) {
                address child = address(uint160(0xB000 + ++n));
                _join(child, leaders[i]);
                _activate(child, 1);
                vm.warp(START + 50 * DAY + n * 3 * DAY); // from START: block.timestamp + vm.warp miscompiles
                vm.prank(child);
                rewards.claimDaily();
                _fund(child, 47 ether + 1); // 47 + 1 wei of deposit, the rest credit
                _setNext(child, 0);
                vm.prank(child);
                rewards.activate(0);
            }
        }
        uint256 mar = rewards.currentMonth();
        assertGt(rewards.monthPoolCredit(mar), 0);
        vm.warp(APR_01);
        for (uint256 i = 0; i < 3; i++) {
            assertGt(_claimLeader(leaders[i]), 0);
            assertLe(rewards.leadershipCredit(), rewards.leadershipPool());
            _assertSolvent();
        }
        assertLe(rewards.monthCreditClaimed(mar), rewards.monthPoolCredit(mar));
    }

    function test_creditActivationsAreFirstComeFirstServed() public {
        _deploy(); // an empty reward pool
        _join(bob, sponsor);
        _activate(sponsor, 1);
        _activate(bob, 1);
        _creditFromTier1(alice, 50);
        assertEq(_claim(bob), 50 ether);
        _setNext(alice, 0);
        _setNext(bob, 0);
        _reserve(40 ether); // enough for one credit-paid $50
        vm.prank(alice);
        rewards.activate(0);
        vm.prank(bob);
        vm.expectRevert("INSUFFICIENT_REWARD_POOL");
        rewards.activate(0);

        _fund(bob, 50 ether); // a deposit always activates
        vm.prank(bob);
        rewards.activate(0);
        assertEq(rewards.rewardCredit(bob), 50 ether);
        assertEq(funder.rewardPool(), 0);
        _assertSolvent();
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
        uint256 when = START;
        for (uint256 step = 0; step < 40; step++) {
            uint256 x = uint256(keccak256(abi.encode(seed, step)));
            address u = users[x % 6];
            uint256 tier = (x >> 8) % 2;
            uint256 op = (x >> 16) % 4;
            when += ((x >> 24) % 3) * DAY;
            vm.warp(when);
            if (op == 0 && rewards.tierCapping(u, tier) == 0) {
                _activate(u, tier);
            } else if (op == 1) {
                _reserve((x >> 32) % 20 ether);
            } else if (op == 3) {
                uint256 amount = 20 ether;
                if (rewards.withdrawable(u) >= amount && block.timestamp > gateway.coolDown(u)) {
                    vm.prank(u);
                    gateway.withdraw(amount);
                }
            } else if (block.timestamp >= rewards.lastClaim(u) + DAY && rewards.pendingDaily(u) > 0) {
                _claim(u);
            }

            // Money members can take out without the pool, plus the pool and leadership, is all in the funder.
            uint256 owed = rewards.leadershipPool() + funder.rewardPool();
            uint256 wallets;
            uint256 credits;
            uint256 agents;
            for (uint256 i = 0; i < 6; i++) {
                wallets += rewards.walletBalance(users[i]);
                credits += rewards.rewardCredit(users[i]);
                agents += rewards.agentBalance(users[i]);
            }
            owed += wallets - credits + agents;
            assertGe(usdt.balanceOf(address(funder)), owed);
            assertEq(rewards.totalWalletBalance(), wallets);
            assertEq(rewards.totalRewardCredit(), credits);
            assertEq(rewards.totalAgentBalance(), agents);
        }
    }
}
