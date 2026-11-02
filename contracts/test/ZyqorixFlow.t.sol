// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {ZyqorixAccounts} from "../accounts.sol";
import {ZyqorixFunder} from "../funder.sol";
import {ZyqorixGateway} from "../gateway.sol";
import {ZyqorixLiquidity} from "../liquidity.sol";
import {ZyqorixRegister} from "../register.sol";
import {ZyqorixRewards} from "../rewards.sol";
import {ZyqorixVesting} from "../vesting.sol";

contract MockToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function mint(address to, uint256 v) external { balanceOf[to] += v; totalSupply += v; }
    function burn(uint256 v) external { balanceOf[msg.sender] -= v; totalSupply -= v; }
    function approve(address s, uint256 v) external returns (bool) { allowance[msg.sender][s] = v; return true; }

    function transfer(address to, uint256 v) external returns (bool) {
        balanceOf[msg.sender] -= v;
        balanceOf[to] += v;
        return true;
    }

    function transferFrom(address f, address to, uint256 v) external returns (bool) {
        if (msg.sender != f) allowance[f][msg.sender] -= v;
        balanceOf[f] -= v;
        balanceOf[to] += v;
        return true;
    }
}

/// @dev 1:1 pool with a flat TWAP.
contract MockPool {
    address public token0;
    address public token1;
    uint24 public constant fee = 2500;
    int24 public constant tickSpacing = 50;
    bool public observeFails;

    constructor(address a, address b) { (token0, token1) = a < b ? (a, b) : (b, a); }
    function setObserveFails(bool v) external { observeFails = v; }
    function increaseObservationCardinalityNext(uint16) external {}

    function observe(uint32[] calldata) external view returns (int56[] memory t, uint160[] memory s) {
        require(!observeFails, "OLD");
        t = new int56[](2);
        s = new uint160[](2);
    }
}

contract MockRouter {
    struct Params {
        address tokenIn; address tokenOut; uint24 fee; address recipient;
        uint256 deadline; uint256 amountIn; uint256 amountOutMinimum; uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(Params calldata p) external returns (uint256) {
        MockToken(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn);
        MockToken(p.tokenOut).mint(p.recipient, p.amountIn);
        return p.amountIn;
    }
}

contract MockPositionManager {
    function positions(uint256) external pure returns (
        uint96, address, address, address, uint24, int24, int24, uint128, uint256, uint256, uint128, uint128
    ) {
        return (0, address(0), address(0), address(0), 0, 0, 0, 100, 0, 0, 0, 0);
    }

    fallback(bytes calldata) external payable returns (bytes memory) {
        return abi.encode(uint256(7), uint128(100), uint256(0), uint256(0));
    }
    receive() external payable {}
}

/// @dev Every member action, in order, on the real contracts. Only PancakeSwap is mocked.
contract ZyqorixFlowTest is Test {
    uint256 constant JAN_15_2027 = 1799971200;
    uint256 constant FEB_01_2027 = 1801440000;
    uint256 constant DAY = 1 days;

    MockToken usdt;
    MockToken zqr;
    MockPool pool;
    MockRouter router;
    MockPositionManager pm;

    ZyqorixAccounts accounts;
    ZyqorixFunder funder;
    ZyqorixGateway gateway;
    ZyqorixVesting vesting;
    ZyqorixRewards rewards;
    ZyqorixRegister reg;
    ZyqorixLiquidity lp;

    address owner = address(this);
    address trading = makeAddr("trading");
    address leader = makeAddr("leader");
    address sponsor = makeAddr("sponsor");
    address alice = makeAddr("alice");

    function setUp() public {
        vm.warp(JAN_15_2027);
        usdt = new MockToken();
        zqr = new MockToken();
        pool = new MockPool(address(usdt), address(zqr));
        router = new MockRouter();
        pm = new MockPositionManager();

        accounts = new ZyqorixAccounts();
        funder = new ZyqorixFunder(address(accounts), address(usdt));
        gateway = new ZyqorixGateway(address(accounts), address(usdt), address(funder));
        funder.setGateway(address(gateway));
        funder.setTradingWallet(trading);
        vesting = new ZyqorixVesting(address(accounts), address(zqr), 30 days);
        zqr.mint(address(vesting), 500_000_000 ether);
        rewards = new ZyqorixRewards(address(accounts), address(gateway), address(vesting), 1 days);
        accounts.addAdmin(address(rewards));
        gateway.setRewards(address(rewards));
        funder.setRewards(address(rewards));
        reg = new ZyqorixRegister(address(accounts), address(gateway));
        accounts.addAdmin(address(reg));
        lp = new ZyqorixLiquidity(address(usdt), address(zqr), address(pm), address(router));
        lp.initializePool(address(pool));
        lp.initializeApproval();
        gateway.setLiquidity(address(lp));

        usdt.mint(trading, 100_000 ether);
        vm.startPrank(trading);
        usdt.approve(address(funder), 100_000 ether);
        funder.fundRewards(100_000 ether);
        vm.stopPrank();
    }

    function _mintPosition() internal {
        usdt.mint(address(this), 1_000 ether);
        zqr.mint(address(this), 1_000 ether);
        usdt.approve(address(lp), 1_000 ether);
        zqr.approve(address(lp), 1_000 ether);
        lp.depositUSDT(1_000 ether);
        lp.depositToken(1_000 ether);
        lp.initializePosition();
    }

    function _register(address user, address up) internal {
        usdt.mint(user, 5_000 ether);
        vm.prank(user);
        usdt.approve(address(gateway), type(uint256).max);
        vm.prank(user, user);
        reg.register(up);
    }

    function _activate(address user, uint256 tier) internal {
        vm.prank(user);
        rewards.activate(tier);
    }

    function _deposit(address user, uint256 amount) internal {
        vm.prank(user);
        gateway.deposit(address(usdt), amount);
    }

    /// @dev Steps 1 to 10 with TOKENID 0: the pool gives a price, but no position exists.
    function test_fullFlowBeforeThePositionIsMinted() public {
        assertEq(lp.TOKENID(), 0);

        // 1) Register and initial deposit.
        // A sponsor must be active, so each level activates before the next one joins.
        _register(leader, owner);
        rewards.setAgent(leader, true);

        // 2) Activate. The price reads from the pool, and the liquidity step is skipped.
        _activate(leader, 0);
        _register(sponsor, leader);
        _activate(sponsor, 0);

        // 9) The direct referral lands in the sponsor's wallet and uses their capping.
        assertEq(rewards.walletBalance(leader), 2.5 ether);
        assertEq(rewards.capping(leader), 147.5 ether);

        _register(alice, sponsor);
        assertTrue(accounts.isUser(alice));
        assertEq(rewards.walletBalance(alice), 50 ether);
        assertEq(usdt.balanceOf(alice), 4_950 ether);
        _activate(alice, 0);
        assertEq(rewards.walletBalance(alice), 0);
        assertEq(rewards.capping(alice), 150 ether);
        assertEq(rewards.walletBalance(sponsor), 2.5 ether);
        assertEq(rewards.capping(sponsor), 147.5 ether);
        assertEq(vesting.positionCount(alice), 1);
        assertEq(vesting.getPosition(alice, 0).amount, 50 ether); // 1:1 in this mock
        assertEq(usdt.balanceOf(address(lp)), 0);
        assertEq(usdt.balanceOf(trading), 15 ether); // 10% of 150
        assertEq(usdt.balanceOf(address(funder)), 100_135 ether); // the liquidity share stayed here
        assertEq(rewards.agentBalance(leader), 7.5 ether); // 5% of all three, no capping used

        // 3) Claim passive.
        vm.warp(JAN_15_2027 + DAY + 1);
        vm.prank(alice);
        assertEq(rewards.claimDaily(), 0.5 ether);
        assertEq(rewards.walletBalance(alice), 0.5 ether);
        assertEq(rewards.capping(alice), 149.5 ether);

        // 4) Claim generation: 10% of alice's claim, from each sponsor's own capping.
        assertEq(rewards.generationBalance(sponsor), 0.05 ether);
        assertEq(rewards.generationBalance(leader), 0.05 ether);
        assertEq(rewards.capping(sponsor), 146.95 ether); // 147.5 - 0.5 daily - 0.05 generation
        vm.prank(sponsor);
        assertEq(rewards.claimGeneration(), 0.05 ether);
        assertEq(rewards.walletBalance(sponsor), 2.55 ether);

        // 5) Claim agent: paid to the wallet, cooldown only, no fee.
        uint256 leaderCash = usdt.balanceOf(leader);
        vm.prank(leader);
        gateway.withdrawAgent(7.5 ether);
        assertEq(usdt.balanceOf(leader), leaderCash + 7.5 ether);
        assertEq(rewards.agentBalance(leader), 0);

        // 6) Deposit.
        _deposit(alice, 120 ether);
        assertEq(rewards.walletBalance(alice), 120.5 ether);

        // 7) New tier: only the next one, each once.
        vm.startPrank(alice);
        vm.expectRevert("TIER_USED");
        rewards.activate(0);
        vm.expectRevert("TIER_SKIPPED");
        rewards.activate(2);
        rewards.activate(1);
        vm.expectRevert("TIER_USED");
        rewards.activate(1);
        vm.expectRevert("TIER_LOCKED");
        rewards.activate(2); // next in line, but the 60 days haven't passed
        vm.stopPrank();
        assertEq(rewards.nextTier(alice), 2);
        assertEq(rewards.capping(alice), 449.5 ether);
        assertEq(rewards.walletBalance(alice), 20.5 ether);

        // 8) Withdraw. The swap and burn are skipped, and the fee stays with the funder.
        vm.warp(JAN_15_2027 + 3 * DAY);
        uint256 cash = usdt.balanceOf(alice);
        uint256 funderBefore = usdt.balanceOf(address(funder));
        vm.prank(alice);
        gateway.withdraw(20 ether);
        assertEq(usdt.balanceOf(alice), cash + 18 ether);
        assertEq(usdt.balanceOf(address(funder)), funderBefore - 18 ether);
        assertEq(usdt.balanceOf(address(gateway)), 0);
        assertEq(usdt.balanceOf(address(router)), 0);
        assertEq(zqr.totalSupply(), 500_000_000 ether);

        // 10) Leadership: 12.5 pooled, shared by direct volume, no capping used.
        vm.warp(FEB_01_2027);
        uint256 capBefore = rewards.capping(sponsor);
        uint256 walletBefore = rewards.walletBalance(sponsor);
        assertEq(rewards.pendingLeadership(sponsor), 9.375 ether); // 150 of the 200 volume
        vm.prank(sponsor);
        assertEq(rewards.claimLeadership(), 9.375 ether);
        assertEq(rewards.walletBalance(sponsor), walletBefore + 9.375 ether);
        assertEq(rewards.capping(sponsor), capBefore);
        vm.prank(leader);
        assertEq(rewards.claimLeadership(), 3.125 ether);
        assertEq(rewards.leadershipPool(), 0);

        // The funder still covers every wallet balance and the reward pool.
        uint256 wallets = rewards.walletBalance(leader) + rewards.walletBalance(sponsor) + rewards.walletBalance(alice);
        assertGe(usdt.balanceOf(address(funder)), wallets + funder.rewardPool());
    }

    /// @dev The same activation and withdrawal once the position exists.
    function test_liquidityVestingAndBurnRunOnceThePositionIsMinted() public {
        _mintPosition();
        _register(sponsor, owner);
        _activate(sponsor, 0);
        _register(alice, sponsor);
        _activate(alice, 0);
        assertEq(usdt.balanceOf(address(lp)), 1_050 ether); // 50% of both went to the position
        assertEq(vesting.positionCount(alice), 1);
        assertEq(vesting.getPosition(alice, 0).amount, 50 ether); // 1:1 in this mock

        _deposit(alice, 50 ether);
        vm.warp(JAN_15_2027 + 2 * DAY);
        uint256 funderBefore = usdt.balanceOf(address(funder));
        vm.prank(alice);
        gateway.withdraw(20 ether);
        assertEq(usdt.balanceOf(address(funder)), funderBefore - 20 ether);
        assertEq(usdt.balanceOf(address(router)), 2 ether); // the fee was swapped
        assertEq(zqr.balanceOf(address(gateway)), 0);
        assertEq(zqr.totalSupply(), 500_000_000 ether + 1_000 ether); // bought 2, burned 2
    }

    /// @dev A pool can exist with no position: vesting runs on its price, but nothing is added or swapped.
    function test_tokenIdZeroSkipsLiquidityAndBurnButNotVesting() public {
        _register(alice, owner);
        _activate(alice, 0);
        assertEq(vesting.positionCount(alice), 1);
        assertEq(usdt.balanceOf(address(lp)), 0);

        _deposit(alice, 50 ether);
        vm.warp(JAN_15_2027 + 2 * DAY);
        uint256 funderBefore = usdt.balanceOf(address(funder));
        vm.prank(alice);
        gateway.withdraw(20 ether);
        assertEq(usdt.balanceOf(address(router)), 0);
        assertEq(usdt.balanceOf(address(funder)), funderBefore - 18 ether);
    }

    function _nextFunder() internal returns (ZyqorixFunder next) {
        next = new ZyqorixFunder(address(accounts), address(usdt));
        next.setGateway(address(gateway));
        next.setRewards(address(rewards));
        next.setTradingWallet(trading);
    }

    function test_migrateFunderMovesTheMoneyAndTheLedger() public {
        _register(sponsor, owner);
        _activate(sponsor, 0);
        _register(alice, sponsor);
        _activate(alice, 0);
        vm.warp(JAN_15_2027 + 2 * DAY);

        uint256 balance = usdt.balanceOf(address(funder));
        uint256 pool = funder.rewardPool();
        uint256 reserved = rewards.unreservedPool();
        assertEq(funder.tradingCapitalOut(), 10 ether);

        ZyqorixFunder next = _nextFunder();
        gateway.migrateFunder(address(next));

        assertEq(address(gateway.funder()), address(next));
        assertEq(usdt.balanceOf(address(funder)), 0);
        assertEq(usdt.balanceOf(address(next)), balance);
        assertEq(next.rewardPool(), pool);
        assertEq(next.tradingCapitalOut(), 10 ether);
        assertEq(rewards.unreservedPool(), reserved);

        // Claims, deposits, withdrawals and activations all carry on against the new funder.
        vm.prank(alice);
        assertEq(rewards.claimDaily(), 1 ether);
        assertEq(next.rewardPool(), pool - 1 ether);

        _deposit(alice, 119 ether);
        assertEq(usdt.balanceOf(address(next)), balance + 119 ether);
        _activate(alice, 1);
        assertEq(next.tradingCapitalOut(), 20 ether);

        vm.warp(JAN_15_2027 + 4 * DAY);
        uint256 cash = usdt.balanceOf(alice);
        vm.prank(alice);
        gateway.withdraw(20 ether);
        assertEq(usdt.balanceOf(alice), cash + 18 ether);

        // Capital still comes back first: $20 is outstanding, so only the rest is profit.
        usdt.mint(trading, 5 ether); // $5 of trading profit on top of the $20 it was sent
        vm.startPrank(trading);
        usdt.approve(address(next), 25 ether);
        next.fundRewards(25 ether);
        vm.stopPrank();
        assertEq(next.tradingCapitalReturned(), 20 ether);
        assertEq(next.rewardPool(), pool - 1 ether + 5 ether);
    }

    function test_oldFunderIsCutOffAfterMigrating() public {
        gateway.migrateFunder(address(_nextFunder()));
        vm.startPrank(trading);
        usdt.mint(trading, 10 ether);
        usdt.approve(address(funder), 10 ether);
        vm.expectRevert("NOT_FUNDER");
        funder.fundRewards(10 ether);
        vm.stopPrank();

        vm.expectRevert("LEDGER_NOT_EMPTY"); // going back would overwrite a live ledger's copy
        gateway.migrateFunder(address(funder));
    }

    function test_migrateFunderGates() public {
        ZyqorixFunder next = _nextFunder();

        vm.prank(alice);
        vm.expectRevert("NOT_OWNER");
        gateway.migrateFunder(address(next));

        vm.expectRevert("SAME_FUNDER");
        gateway.migrateFunder(address(funder));

        ZyqorixFunder noRewards = new ZyqorixFunder(address(accounts), address(usdt));
        noRewards.setGateway(address(gateway));
        vm.expectRevert("FUNDER_NOT_LINKED");
        gateway.migrateFunder(address(noRewards));

        ZyqorixFunder noWallet = new ZyqorixFunder(address(accounts), address(usdt));
        noWallet.setGateway(address(gateway));
        noWallet.setRewards(address(rewards));
        vm.expectRevert("TRADING_WALLET_NOT_SET");
        gateway.migrateFunder(address(noWallet));

        vm.prank(alice);
        vm.expectRevert("NOT_GATEWAY");
        next.importLedger(1, 0, 0, 1);

        assertEq(address(gateway.funder()), address(funder)); // failed attempts change nothing
    }

    function test_lockFunderClosesMigrationForGood() public {
        _mintPosition();
        lp.lockLiquidity();
        gateway.lockFunder();
        ZyqorixFunder next = _nextFunder();
        vm.expectRevert("FUNDER_LOCKED");
        gateway.migrateFunder(address(next));
    }

    function test_activationNeedsAReadablePrice() public {
        ZyqorixLiquidity noPool = new ZyqorixLiquidity(address(usdt), address(zqr), address(pm), address(router));
        gateway.setLiquidity(address(noPool));
        _register(alice, owner);
        vm.prank(alice);
        vm.expectRevert("Pool not initialized");
        rewards.activate(0);

        gateway.setLiquidity(address(lp));
        pool.setObserveFails(true); // no TWAP history yet
        vm.prank(alice);
        vm.expectRevert("TwapPriceFailed");
        rewards.activate(0);
        assertEq(rewards.walletBalance(alice), 50 ether);
        assertEq(rewards.nextTier(alice), 0);

        pool.setObserveFails(false);
        _activate(alice, 0);
        assertEq(rewards.capping(alice), 150 ether);
    }

    function test_memberDepositMinimum() public {
        _register(alice, owner);
        assertEq(gateway.minDeposit(), 50 ether);

        vm.startPrank(alice);
        vm.expectRevert("BELOW_MIN_DEPOSIT");
        gateway.deposit(address(usdt), 50 ether - 1);
        gateway.deposit(address(usdt), 50 ether);
        vm.stopPrank();
        assertEq(rewards.walletBalance(alice), 100 ether);

        vm.prank(alice);
        vm.expectRevert("NOT_AUTH");
        gateway.setMinDeposit(1 ether);

        gateway.setMinDeposit(10 ether);
        _deposit(alice, 10 ether);
        assertEq(rewards.walletBalance(alice), 110 ether);
    }

    /// @dev Register sets its own amount through depositFor, so a smaller initial deposit still works.
    function test_initialDepositIsNotBoundByTheMinimum() public {
        reg.setInitialDeposit(20 ether);
        _register(alice, owner);
        assertEq(rewards.walletBalance(alice), 20 ether);
    }

    function test_sponsorMustBeActiveOrTheRoot() public {
        _register(sponsor, owner); // the root can always sponsor

        usdt.mint(alice, 100 ether);
        vm.prank(alice);
        usdt.approve(address(gateway), type(uint256).max);
        vm.prank(alice, alice);
        vm.expectRevert("SPONSOR_NOT_ACTIVE");
        reg.register(sponsor); // registered, but no tier yet
        assertFalse(accounts.isUser(alice));
        assertEq(usdt.balanceOf(alice), 100 ether);

        _activate(sponsor, 0);
        vm.prank(alice, alice);
        reg.register(sponsor);
        assertTrue(accounts.isUser(alice));

        // Past their capping the sponsor stops qualifying, even before anything settles it.
        vm.warp(JAN_15_2027 + 300 * DAY);
        assertGt(rewards.capping(sponsor), 0);
        assertFalse(rewards.isActive(sponsor));
        address late = makeAddr("late");
        usdt.mint(late, 100 ether);
        vm.prank(late);
        usdt.approve(address(gateway), type(uint256).max);
        vm.prank(late, late);
        vm.expectRevert("SPONSOR_NOT_ACTIVE");
        reg.register(sponsor);
    }

    function test_tiersRunInOrderOnceEachUpToTheHighest() public {
        _register(alice, owner);
        usdt.mint(alice, 5_000 ether);
        _deposit(alice, 3_100 ether);
        vm.warp(JAN_15_2027 + 120 * DAY);

        vm.prank(alice);
        vm.expectRevert("TIER_SKIPPED");
        rewards.activate(5);

        for (uint256 tier = 0; tier < 6; tier++) _activate(alice, tier);
        assertEq(rewards.nextTier(alice), 6);
        assertEq(rewards.activeTiers(alice).length, 6);

        vm.startPrank(alice);
        vm.expectRevert("TIER_ACTIVE");
        rewards.activate(5); // still has capping
        vm.expectRevert("TIER_USED");
        rewards.activate(4);
        vm.expectRevert("BAD_TIER");
        rewards.activate(6);
        vm.stopPrank();
    }

    function test_lastTierReopensEveryTimeItsCappingIsZero() public {
        _register(alice, owner);
        usdt.mint(alice, 5_000 ether);
        _deposit(alice, 3_100 ether);
        vm.warp(JAN_15_2027 + 120 * DAY);
        for (uint256 tier = 0; tier < 6; tier++) _activate(alice, tier);

        for (uint256 round = 1; round <= 2; round++) {
            vm.warp(JAN_15_2027 + (120 + round * 1_000) * DAY); // every open tier caps
            vm.prank(alice);
            rewards.claimDaily();
            assertEq(rewards.capping(alice), 0);

            vm.startPrank(alice);
            vm.expectRevert("TIER_USED");
            rewards.activate(4); // the earlier tiers stay used
            rewards.activate(5);
            vm.expectRevert("TIER_ACTIVE");
            rewards.activate(5); // not again until this one caps
            vm.stopPrank();
            assertEq(rewards.capping(alice), 4_800 ether);
            assertEq(rewards.tierCapping(alice, 5), 4_800 ether);
            assertEq(rewards.activeTiers(alice).length, 1);
            assertEq(vesting.positionCount(alice), 6 + round);
        }
    }

    function test_aCappedTierCannotBeActivatedAgain() public {
        _register(alice, owner);
        _activate(alice, 0);
        vm.warp(JAN_15_2027 + 300 * DAY); // $50 at 1% caps at $150
        vm.prank(alice);
        rewards.claimDaily();
        assertEq(rewards.capping(alice), 0);

        vm.prank(alice);
        vm.expectRevert("TIER_USED");
        rewards.activate(0);
    }

    function test_referralStopsAtTheCapping() public {
        _register(sponsor, owner);
        _activate(sponsor, 0);
        _register(alice, sponsor);
        vm.warp(JAN_15_2027 + 299 * DAY); // $0.50 of capping left
        _activate(alice, 0);
        assertEq(rewards.walletBalance(sponsor), 0.5 ether); // wanted 2.5
        assertEq(rewards.capping(sponsor), 0);
    }
}
