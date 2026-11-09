// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test, stdStorage, StdStorage} from "forge-std/Test.sol";
import {ZyqorixAccounts} from "../accounts.sol";
import {ExchangerDisbursement} from "../exchangerdisbursement.sol";
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

/// @dev Stand-in for a Safe multisig: a contract owner that acts only through `exec`, with no receive() at all
///      (stricter than a real Safe, which accepts BNB). Proves nothing assumes the owner is an EOA.
contract MockMultisig {
    address immutable signer;
    constructor() { signer = msg.sender; }
    function exec(address target, bytes calldata data) external returns (bytes memory out) {
        require(msg.sender == signer, "NOT_SIGNER");
        bool ok;
        (ok, out) = target.call(data);
        if (!ok) assembly { revert(add(out, 32), mload(out)) }
    }
}

/// @dev Every member action, in order, on the real contracts. Only PancakeSwap is mocked.
contract ZyqorixFlowTest is Test {
    using stdStorage for StdStorage;

    /// @dev USDT's BSC mainnet address, hardcoded in funder, gateway, liquidity and the exchanger.
    address constant USDT_ADDR = 0x55d398326f99059fF775485246999027B3197955;
    /// @dev ZQR's mainnet address, hardcoded in vesting.sol and liquidity.sol. The mock is etched there.
    address constant ZQR = 0x43ADE7aE5E14e6dadD0f6967a0aDEADe56095e70;
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
        // USDT's mainnet address is hardcoded in the contracts: etch the mock there.
        vm.etch(USDT_ADDR, type(MockToken).runtimeCode);
        usdt = MockToken(USDT_ADDR);
        vm.etch(ZQR, type(MockToken).runtimeCode);
        zqr = MockToken(ZQR);
        pool = new MockPool(address(usdt), address(zqr));
        router = new MockRouter();
        pm = new MockPositionManager();

        accounts = new ZyqorixAccounts();
        funder = new ZyqorixFunder(address(accounts));
        gateway = new ZyqorixGateway(address(accounts), address(funder));
        funder.setGateway(address(gateway));
        funder.setTradingWallet(trading);
        vesting = new ZyqorixVesting(address(accounts), 30 days);
        zqr.mint(address(vesting), 500_000_000 ether);
        rewards = new ZyqorixRewards(address(accounts), address(gateway), address(vesting), 1 days);
        accounts.addAdmin(address(rewards));
        gateway.setRewards(address(rewards));
        funder.setRewards(address(rewards));
        reg = new ZyqorixRegister(address(accounts), address(gateway));
        accounts.addAdmin(address(reg));
        lp = new ZyqorixLiquidity(address(pm), address(router));
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
        assertEq(usdt.balanceOf(trading), 90 ether); // 60% of 150
        assertEq(usdt.balanceOf(address(funder)), 100_060 ether); // the liquidity share stayed here
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

        // 8) Withdraw. The swap and burn are skipped, and the fee is booked into the reward pool.
        vm.warp(JAN_15_2027 + 3 * DAY);
        uint256 cash = usdt.balanceOf(alice);
        uint256 funderBefore = usdt.balanceOf(address(funder));
        uint256 poolBefore = funder.rewardPool();
        vm.prank(alice);
        gateway.withdraw(20 ether);
        assertEq(funder.rewardPool(), poolBefore + 2 ether);
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
        assertEq(usdt.balanceOf(address(lp)), 1_020 ether); // 20% of both went to the position
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

    /// @dev End to end with an empty reward pool: activation and the daily claim work, the deposit part can be
    ///      withdrawn, the reward part waits for fundRewards.
    function test_emptyPoolActivationAndWithdrawalWaitForFunding() public {
        uint256 pool = funder.rewardPool();
        stdstore.target(address(funder)).sig("rewardPool()").checked_write(uint256(0));
        _register(alice, owner);
        _activate(alice, 0);
        _deposit(alice, 50 ether);
        vm.warp(JAN_15_2027 + 20 * DAY);
        vm.prank(alice);
        assertEq(rewards.claimDaily(), 10 ether);
        vm.warp(JAN_15_2027 + 22 * DAY);

        vm.prank(alice);
        vm.expectRevert("INSUFFICIENT_REWARD_POOL");
        gateway.withdraw(60 ether); // 50 of deposit, 10 of reward credit
        vm.prank(alice);
        gateway.withdraw(40 ether);

        vm.warp(JAN_15_2027 + 24 * DAY);
        vm.prank(alice);
        vm.expectRevert("INSUFFICIENT_REWARD_POOL");
        gateway.withdraw(20 ether);
        stdstore.target(address(funder)).sig("rewardPool()").checked_write(pool);
        vm.prank(alice);
        gateway.withdraw(20 ether);
        assertEq(rewards.walletBalance(alice), 0);
        assertEq(funder.rewardPool(), pool - 8 ether); // 10 drawn, the last 2 fee booked back
    }

    function test_unreadablePriceFallsBackToLastPrice() public {
        // No pool bound yet: the TWAP read reverts, so the seeded lastPrice (0.001) prices the position.
        ZyqorixLiquidity noPool = new ZyqorixLiquidity(address(pm), address(router));
        gateway.setLiquidity(address(noPool));
        _register(alice, owner);
        vm.expectEmit(address(rewards));
        emit ZyqorixRewards.PriceFallbackUsed(alice, 1e15);
        vm.prank(alice);
        rewards.activate(0);
        assertEq(vesting.getPosition(alice, 0).amount, 50_000 ether);
        assertEq(rewards.capping(alice), 150 ether);
        assertEq(rewards.lastPriceAt(), 0);

        // Oracle without history: same fallback.
        gateway.setLiquidity(address(lp));
        pool.setObserveFails(true);
        _register(sponsor, owner);
        vm.prank(sponsor);
        rewards.activate(0);
        assertEq(vesting.getPosition(sponsor, 0).amount, 50_000 ether);

        // Once the TWAP reads, it prices the position (1:1 here) and becomes lastPrice.
        pool.setObserveFails(false);
        _deposit(alice, 100 ether);
        _activate(alice, 1);
        assertEq(vesting.getPosition(alice, 1).amount, 100 ether);
        assertEq(rewards.lastPrice(), 1 ether);
        assertEq(rewards.lastPriceAt(), block.timestamp);
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
        _activate(alice, 0); // the 60/120-day counters run from the first activation
        vm.warp(JAN_15_2027 + 120 * DAY);

        vm.prank(alice);
        vm.expectRevert("TIER_SKIPPED");
        rewards.activate(5);

        for (uint256 tier = 1; tier < 6; tier++) _activate(alice, tier);
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
        _activate(alice, 0); // the 60/120-day counters run from the first activation
        vm.warp(JAN_15_2027 + 120 * DAY);
        for (uint256 tier = 1; tier < 6; tier++) _activate(alice, tier);

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
            assertEq(rewards.capping(alice), 3_200 ether); // 2x every time, not only the first
            assertEq(rewards.tierCapping(alice, 5), 3_200 ether);
            assertEq(rewards.activeTiers(alice).length, 1);
            assertEq(vesting.positionCount(alice), 6 + round);
        }
    }

    function test_lastTierGivesTwoTimesCapping() public {
        _register(alice, owner);
        usdt.mint(alice, 5_000 ether);
        _deposit(alice, 3_100 ether);
        _activate(alice, 0); // the 60/120-day counters run from the first activation
        vm.warp(JAN_15_2027 + 120 * DAY);
        for (uint256 tier = 1; tier < 5; tier++) _activate(alice, tier);
        assertEq(rewards.tierCapping(alice, 4), 2_400 ether); // $800 keeps 3x

        uint256 pool = funder.rewardPool();
        uint256 capping = rewards.capping(alice);
        _activate(alice, 5);

        assertEq(rewards.tierCapping(alice, 5), 3_200 ether);
        assertEq(rewards.capping(alice) - capping, 3_200 ether);
        assertEq(funder.rewardPool(), pool); // nothing is reserved from the pool at activation
        assertEq(rewards.capBps(4), 30_000);
        assertEq(rewards.capBps(5), 20_000);
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

    /// @dev The funder's trading wallet is the exchanger disbursement contract: an activation's trading
    ///      share lands there and only leaves split equally across the exchangers.
    function test_tradingShareGoesToTheExchangerDisbursement() public {
        ExchangerDisbursement disb = new ExchangerDisbursement(owner);
        address ex1 = makeAddr("ex1");
        address ex2 = makeAddr("ex2");
        disb.addExchanger(ex1);
        disb.addExchanger(ex2);
        funder.setTradingWallet(address(disb));

        _register(leader, owner);
        uint256 outBefore = funder.tradingCapitalOut();
        _activate(leader, 0);
        uint256 share = funder.tradingCapitalOut() - outBefore;
        assertGt(share, 0);
        assertEq(usdt.balanceOf(address(disb)), share);

        vm.prank(ex1);
        disb.disburseFunding();
        assertEq(usdt.balanceOf(ex1), share / 2);
        assertEq(usdt.balanceOf(ex2), share / 2);
        assertEq(usdt.balanceOf(address(disb)), share % 2);
    }

    /* ----------------------------- Funding wallets ---------------------------- */
    address fundingWallet = makeAddr("fundingWallet");

    /// @dev The funder itself pulls the funding wallets; this adds the first one.
    function _puller() internal returns (ZyqorixFunder puller) {
        puller = funder;
        puller.addFundingWallet(fundingWallet);
    }

    /// @dev Alice holds 50 of deposit and 10 of reward credit, and the reward pool is empty.
    function _aliceWithCreditAndEmptyPool() internal {
        stdstore.target(address(funder)).sig("rewardPool()").checked_write(uint256(0));
        _register(alice, owner);
        _activate(alice, 0);
        _deposit(alice, 50 ether);
        vm.warp(JAN_15_2027 + 20 * DAY);
        vm.prank(alice);
        assertEq(rewards.claimDaily(), 10 ether);
        vm.warp(JAN_15_2027 + 22 * DAY);
    }

    function test_pullerPendingIsBalanceCappedByAllowance() public {
        ZyqorixFunder puller = funder;
        usdt.mint(fundingWallet, 30 ether);
        assertEq(puller.pendingFunding(), 0); // no funding wallet set
        assertEq(puller.pullFunding(), 0);
        puller.addFundingWallet(fundingWallet);
        assertEq(puller.pendingFunding(), 0); // not approved yet
        vm.prank(fundingWallet);
        usdt.approve(address(puller), 20 ether);
        assertEq(puller.pendingFunding(), 20 ether);
        vm.prank(fundingWallet);
        usdt.approve(address(puller), type(uint256).max);
        assertEq(puller.pendingFunding(), 30 ether);
        vm.prank(fundingWallet);
        usdt.approve(address(puller), 0); // revoked
        assertEq(puller.pendingFunding(), 0);
        assertEq(puller.pullFunding(), 0);
        assertEq(usdt.balanceOf(fundingWallet), 30 ether);
    }

    /// @dev A pull is booked exactly like fundRewards: all of it is trading profit for the reward pool. The trading
    ///      capital that went out is never repaid first.
    function test_pullBooksEverythingToThePool() public {
        ZyqorixFunder puller = _puller();
        stdstore.target(address(funder)).sig("rewardPool()").checked_write(uint256(0));
        _register(alice, owner);
        uint256 outBefore = funder.tradingCapitalOut();
        _activate(alice, 0); // 60% (30 USDT) leaves for trading
        assertEq(funder.tradingCapitalOut() - outBefore, 30 ether);

        usdt.mint(fundingWallet, 45 ether);
        vm.prank(fundingWallet);
        usdt.approve(address(puller), type(uint256).max);
        uint256 held = usdt.balanceOf(address(funder));
        vm.prank(alice); // anyone can trigger it
        assertEq(puller.pullFunding(), 45 ether);
        assertEq(usdt.balanceOf(fundingWallet), 0);
        assertEq(usdt.balanceOf(address(funder)), held + 45 ether);
        assertEq(funder.rewardPool(), 45 ether);
        assertEq(funder.tradingCapitalOut() - outBefore, 30 ether); // only counted, not repaid
    }

    /// @dev Member deposits already in the funder are never booked into the reward pool by a pull.
    function test_pullNeverBooksMemberDeposits() public {
        ZyqorixFunder puller = _puller();
        _register(alice, owner);
        _deposit(alice, 500 ether);
        uint256 deposits = rewards.walletBalance(alice);
        uint256 pool = funder.rewardPool();
        assertEq(puller.pullFunding(), 0); // the wallet holds nothing
        usdt.mint(fundingWallet, 5 ether);
        vm.prank(fundingWallet);
        usdt.approve(address(puller), type(uint256).max);
        assertEq(puller.pullFunding(), 5 ether); // only what the wallet sent
        assertEq(funder.rewardPool(), pool + 5 ether);
        assertEq(rewards.walletBalance(alice), deposits);
    }

    event RewardsFunded(address indexed from, uint256 amount);

    function test_bookingEmitsRewardsFunded() public {
        ZyqorixFunder puller = _puller();
        usdt.mint(fundingWallet, 7 ether);
        vm.prank(fundingWallet);
        usdt.approve(address(puller), type(uint256).max);
        vm.expectEmit(true, false, false, true, address(funder));
        emit RewardsFunded(address(funder), 7 ether);
        puller.pullFunding();

        usdt.mint(trading, 3 ether);
        vm.startPrank(trading);
        usdt.approve(address(funder), 3 ether);
        vm.expectEmit(true, false, false, true, address(funder));
        emit RewardsFunded(trading, 3 ether);
        funder.fundRewards(3 ether);
        vm.stopPrank();
    }

    /// @dev Returned trading capital must never book as profit, so one wallet can't be both.
    function test_tradingWalletCanNeverBeAFundingWallet() public {
        vm.expectRevert("TRADING_WALLET");
        funder.addFundingWallet(trading);
        funder.addFundingWallet(fundingWallet);
        vm.expectRevert("FUNDING_WALLET");
        funder.setTradingWallet(fundingWallet);
    }

    function test_fundingWalletAdminIsOwnerOnly() public {
        ZyqorixFunder puller = _puller();
        vm.prank(alice);
        vm.expectRevert("NOT_OWNER");
        puller.addFundingWallet(alice);
        ZyqorixFunder unwired = new ZyqorixFunder(address(accounts));
        vm.expectRevert("REWARDS_NOT_SET");
        unwired.pullFunding();
    }

    /// @dev The withdrawal that needs the pool pulls the funding wallet in first, with no other transaction.
    function test_pullerWalletListIsOwnerManagedAndBounded() public {
        ZyqorixFunder puller = _puller();
        assertEq(puller.walletCount(), 1);
        vm.expectRevert("ALREADY_ADDED");
        puller.addFundingWallet(fundingWallet);
        vm.expectRevert("ZERO_ADDRESS");
        puller.addFundingWallet(address(0));
        for (uint256 i = 0; i < 4; i++) puller.addFundingWallet(address(uint160(0xF000 + i)));
        assertEq(puller.walletCount(), 5);
        vm.expectRevert("TOO_MANY_WALLETS");
        puller.addFundingWallet(address(0xF100));

        vm.prank(alice);
        vm.expectRevert("NOT_OWNER");
        puller.removeFundingWallet(fundingWallet);
        vm.expectRevert("NOT_FUNDING_WALLET");
        puller.removeFundingWallet(alice);
        puller.removeFundingWallet(fundingWallet); // the first: the last one moves into its slot
        assertFalse(puller.isFundingWallet(fundingWallet));
        address[] memory list = puller.fundingWallets();
        assertEq(list.length, 4);
        assertEq(list[0], address(uint160(0xF003)));
        puller.removeFundingWallet(address(uint160(0xF003))); // removing the new first again
        puller.removeFundingWallet(address(uint160(0xF001))); // the last one
        list = puller.fundingWallets();
        assertEq(list.length, 2);
        assertEq(list[0], address(uint160(0xF002)));
        assertEq(list[1], address(uint160(0xF000)));
    }

    /// @dev Every approved wallet is pulled and booked once; an unapproved one is skipped; a removed one is left.
    function test_pullSumsEveryFundingWallet() public {
        ZyqorixFunder puller = _puller();
        address second = makeAddr("second");
        address third = makeAddr("third");
        puller.addFundingWallet(second);
        puller.addFundingWallet(third);
        usdt.mint(fundingWallet, 30 ether);
        usdt.mint(second, 40 ether);
        usdt.mint(third, 50 ether); // never approved
        vm.prank(fundingWallet);
        usdt.approve(address(puller), 10 ether);
        vm.prank(second);
        usdt.approve(address(puller), type(uint256).max);
        assertEq(puller.pendingOf(fundingWallet), 10 ether);
        assertEq(puller.pendingOf(third), 0);
        assertEq(puller.pendingFunding(), 50 ether);

        uint256 pool = funder.rewardPool();
        vm.expectEmit(true, true, false, true, address(puller));
        emit ZyqorixFunder.FundingPulled(fundingWallet, 10 ether);
        vm.expectEmit(true, true, false, true, address(puller));
        emit ZyqorixFunder.FundingPulled(second, 40 ether);
        assertEq(puller.pullFunding(), 50 ether);
        assertEq(funder.rewardPool(), pool + 50 ether);
        assertEq(usdt.balanceOf(fundingWallet), 20 ether);
        assertEq(usdt.balanceOf(second), 0);
        assertEq(usdt.balanceOf(third), 50 ether);

        puller.removeFundingWallet(fundingWallet);
        assertEq(puller.pendingFunding(), 0); // its remaining 10 approval no longer counts
        assertEq(puller.pullFunding(), 0);
        assertEq(usdt.balanceOf(fundingWallet), 20 ether);
    }

    function test_withdrawalAutoPullsAcrossWallets() public {
        _aliceWithCreditAndEmptyPool();
        ZyqorixFunder puller = _puller();
        address second = makeAddr("second");
        puller.addFundingWallet(second);
        usdt.mint(fundingWallet, 4 ether);
        usdt.mint(second, 6 ether); // together they cover the 10 of credit
        vm.prank(fundingWallet);
        usdt.approve(address(puller), type(uint256).max);
        vm.prank(second);
        usdt.approve(address(puller), type(uint256).max);
        assertEq(rewards.withdrawable(alice), 60 ether);

        vm.prank(alice);
        gateway.withdraw(60 ether);
        assertEq(usdt.balanceOf(fundingWallet), 0);
        assertEq(usdt.balanceOf(second), 0);
        assertEq(funder.rewardPool(), 6 ether); // the 6 fee was booked back
        assertEq(rewards.rewardCredit(alice), 0);
    }

    /// @dev A wallet whose transferFrom fails is skipped; the others are still booked.
    function test_pullSkipsAFailingWallet() public {
        ZyqorixFunder puller = _puller();
        address second = makeAddr("second");
        puller.addFundingWallet(second);
        usdt.mint(fundingWallet, 30 ether);
        usdt.mint(second, 40 ether);
        vm.prank(fundingWallet);
        usdt.approve(address(puller), type(uint256).max);
        vm.prank(second);
        usdt.approve(address(puller), type(uint256).max);
        vm.mockCallRevert(
            address(usdt),
            abi.encodeWithSelector(usdt.transferFrom.selector, fundingWallet, address(puller), 30 ether),
            "BLOCKED"
        );
        uint256 pool = funder.rewardPool();
        assertEq(puller.pullFunding(), 40 ether);
        assertEq(funder.rewardPool(), pool + 40 ether);
        assertEq(usdt.balanceOf(fundingWallet), 30 ether);
        assertEq(usdt.balanceOf(second), 0);
    }

    /// @dev The worst case for a withdrawal: all five wallets pulled. Measures the gas the app has to cover.
    function test_withdrawalPullingFiveWalletsGas() public {
        _aliceWithCreditAndEmptyPool();
        ZyqorixFunder puller = _puller();
        for (uint256 i = 0; i < 5; i++) {
            address wallet = i == 0 ? fundingWallet : makeAddr(string(abi.encode("w", i)));
            if (i > 0) puller.addFundingWallet(wallet);
            usdt.mint(wallet, 10 ether / 5 + 1 ether);
            vm.prank(wallet);
            usdt.approve(address(puller), type(uint256).max);
        }
        uint256 start = gasleft();
        vm.prank(alice);
        gateway.withdraw(60 ether);
        uint256 used = start - gasleft();
        emit log_named_uint("withdraw with a 5-wallet pull, gas", used);
        assertEq(rewards.rewardCredit(alice), 0);
        assertLt(used, 1_100_000);
    }

    function test_withdrawalAutoPullsTheFundingWallet() public {
        _aliceWithCreditAndEmptyPool();
        ZyqorixFunder puller = _puller();
        usdt.mint(fundingWallet, 45 ether);
        assertEq(rewards.withdrawable(alice), 50 ether); // not approved: only the deposit part

        vm.prank(alice);
        vm.expectRevert("INSUFFICIENT_REWARD_POOL");
        gateway.withdraw(60 ether);
        assertEq(usdt.balanceOf(fundingWallet), 45 ether); // the revert undid the pull too

        vm.prank(fundingWallet);
        usdt.approve(address(puller), type(uint256).max);
        // 45 waiting covers all 10 of the credit.
        assertEq(rewards.withdrawable(alice), 60 ether);
        uint256 before = usdt.balanceOf(alice);
        vm.prank(alice);
        gateway.withdraw(60 ether);
        assertEq(usdt.balanceOf(alice), before + 54 ether); // 10% fee
        assertEq(usdt.balanceOf(fundingWallet), 0);
        assertEq(funder.rewardPool(), 41 ether); // 45 booked, 10 drawn, the 6 fee booked back
        assertEq(rewards.rewardCredit(alice), 0);
    }

    /// @dev A withdrawal the pool already covers never touches the funding wallet.
    function test_noPullWhileThePoolCovers() public {
        ZyqorixFunder puller = _puller();
        usdt.mint(fundingWallet, 30 ether);
        vm.prank(fundingWallet);
        usdt.approve(address(puller), type(uint256).max);
        _register(alice, owner);
        _activate(alice, 0);
        vm.warp(JAN_15_2027 + 40 * DAY);
        vm.prank(alice);
        assertEq(rewards.claimDaily(), 20 ether);
        vm.prank(alice);
        gateway.withdraw(20 ether);
        assertEq(usdt.balanceOf(fundingWallet), 30 ether);
    }

    function test_brokenPullNeverBlocksAWithdrawal() public {
        _aliceWithCreditAndEmptyPool();
        vm.mockCallRevert(address(funder), abi.encodeWithSelector(funder.pullFunding.selector), "PULL_BROKEN");
        vm.mockCallRevert(address(funder), abi.encodeWithSelector(funder.pendingFunding.selector), "PENDING_BROKEN");
        assertEq(rewards.withdrawable(alice), 50 ether); // a reverting pending() doesn't break the view
        vm.prank(alice);
        vm.expectRevert("INSUFFICIENT_REWARD_POOL");
        gateway.withdraw(60 ether);
        vm.prank(alice);
        gateway.withdraw(40 ether); // free part only
        assertEq(rewards.walletBalance(alice), 20 ether);
    }

    /// @dev Paying an activation from reward credit pulls the funding wallet in as well.
    function test_activationFromCreditAutoPulls() public {
        stdstore.target(address(funder)).sig("rewardPool()").checked_write(uint256(0));
        _register(alice, owner);
        _activate(alice, 0);
        vm.warp(JAN_15_2027 + 60 * DAY);
        vm.prank(alice);
        assertEq(rewards.claimDaily(), 30 ether);
        _deposit(alice, 70 ether); // 70 free + 30 credit pays the 100 tier
        vm.prank(alice);
        vm.expectRevert("INSUFFICIENT_REWARD_POOL");
        rewards.activate(1);

        ZyqorixFunder puller = _puller();
        usdt.mint(fundingWallet, 100 ether);
        vm.prank(fundingWallet);
        usdt.approve(address(puller), type(uint256).max);
        _activate(alice, 1);
        assertEq(usdt.balanceOf(fundingWallet), 0);
        assertEq(rewards.rewardCredit(alice), 0);
        assertEq(funder.rewardPool(), 82 ether); // 100 pulled - 18 drawn (the trading 60% of the 30 of credit; no position, so the liquidity share stayed)
    }

    /* ------------------- Sole member: the funder holds little ------------------- */
    address fundingWallet2 = makeAddr("fundingWallet2");

    /// @dev Two funding wallets, each approved and holding exactly `each`.
    function _twoFundingWallets(uint256 each) internal {
        funder.addFundingWallet(fundingWallet);
        funder.addFundingWallet(fundingWallet2);
        usdt.mint(fundingWallet, each);
        usdt.mint(fundingWallet2, each);
        vm.prank(fundingWallet);
        usdt.approve(address(funder), each);
        vm.prank(fundingWallet2);
        usdt.approve(address(funder), each);
    }

    /// @dev The only member on the system: one $50 activation, 200 days of daily rewards claimed (100 of credit).
    ///      The funder holds just the 20 the activation left behind (no position is minted here, so the liquidity
    ///      share stays), and the reward pool is empty.
    function _soleMemberAfter200Days() internal {
        deal(address(usdt), address(funder), 0);
        stdstore.target(address(funder)).sig("rewardPool()").checked_write(uint256(0));
        _register(alice, owner);
        _activate(alice, 0);
        assertEq(usdt.balanceOf(address(funder)), 20 ether); // 50 in, 30 out as trading capital
        vm.warp(JAN_15_2027 + 200 * DAY);
        vm.prank(alice);
        assertEq(rewards.claimDaily(), 100 ether);
        assertEq(rewards.rewardCredit(alice), 100 ether);
    }

    function test_soleMemberWithdrawalPullsFundingWallets() public {
        _soleMemberAfter200Days();
        _twoFundingWallets(100 ether);
        assertEq(rewards.withdrawable(alice), 100 ether); // 200 waiting covers it

        uint256 before = usdt.balanceOf(alice);
        vm.prank(alice);
        gateway.withdraw(100 ether);
        assertEq(usdt.balanceOf(alice), before + 90 ether); // 10% fee
        assertEq(usdt.balanceOf(fundingWallet), 0);
        assertEq(usdt.balanceOf(fundingWallet2), 0);
        assertEq(funder.rewardPool(), 110 ether); // 200 pulled - 100 drawn + the 10 fee booked back
        assertEq(rewards.walletBalance(alice), 0);
    }

    function test_soleMemberReactivatesFromCreditWithoutAnAdmin() public {
        _soleMemberAfter200Days();
        _twoFundingWallets(100 ether);
        _activate(alice, 1); // 100 of credit pays the $100 tier
        assertEq(rewards.nextTier(alice), 2);
        assertEq(rewards.walletBalance(alice), 0);
        assertEq(usdt.balanceOf(fundingWallet) + usdt.balanceOf(fundingWallet2), 0);
        assertEq(funder.rewardPool(), 140 ether); // 200 pulled - 60 drawn (trading 60% of the 100 of credit; no position, so the liquidity share stayed)
    }

    function test_soleMemberWithdrawalStillRevertsWithoutFunding() public {
        _soleMemberAfter200Days();
        vm.prank(alice);
        vm.expectRevert("INSUFFICIENT_REWARD_POOL");
        gateway.withdraw(100 ether);
    }

    function test_shortFunderRevertLeavesTheWalletUntouched() public {
        _register(alice, owner); // 50 of deposit
        deal(address(usdt), address(funder), 10 ether); // short, and no funding wallets to pull
        vm.warp(JAN_15_2027 + DAY + 1);
        uint256 cool = gateway.coolDown(alice);
        vm.prank(alice);
        vm.expectRevert("INSUFFICIENT_FUNDER");
        gateway.withdraw(40 ether);
        assertEq(rewards.walletBalance(alice), 50 ether);
        assertEq(rewards.rewardCredit(alice), 0);
        assertEq(gateway.coolDown(alice), cool);
    }

    function test_freeBalanceWithdrawalPullsWhenTheFunderIsShort() public {
        _register(alice, owner); // 50 of deposit, no reward credit
        deal(address(usdt), address(funder), 10 ether); // the rest is out as trading capital
        _twoFundingWallets(50 ether);
        vm.warp(JAN_15_2027 + DAY + 1); // past the deposit cooldown
        uint256 before = usdt.balanceOf(alice);
        vm.prank(alice);
        gateway.withdraw(40 ether);
        assertEq(usdt.balanceOf(alice), before + 36 ether);
        assertEq(usdt.balanceOf(fundingWallet) + usdt.balanceOf(fundingWallet2), 0);
    }

    function test_agentWithdrawalPullsWhenTheFunderIsShort() public {
        _register(leader, owner);
        rewards.setAgent(leader, true);
        _activate(leader, 0);
        _register(alice, leader);
        _activate(alice, 0);
        assertEq(rewards.agentBalance(leader), 5 ether); // 5% of both activations
        deal(address(usdt), address(funder), 0);
        _twoFundingWallets(50 ether);
        vm.warp(JAN_15_2027 + DAY + 1); // past the deposit cooldown
        uint256 before = usdt.balanceOf(leader);
        vm.prank(leader);
        gateway.withdrawAgent(5 ether);
        assertEq(usdt.balanceOf(leader), before + 5 ether);
        assertEq(usdt.balanceOf(fundingWallet) + usdt.balanceOf(fundingWallet2), 0);
    }

    /* ------------------- Ownership handed to a multisig (runbook 11.3) ------------------- */
    /// @dev The full 11.3 handover: accounts (two-step; covers funder, gateway, rewards, register and vesting),
    ///      liquidity and the exchanger. Root stays the deployer, members keep working, the old key loses
    ///      every owner power, and every owner and admin call still works through the multisig.
    function test_multisigOwnershipHandover() public {
        _mintPosition();
        ExchangerDisbursement disb = new ExchangerDisbursement(owner);
        disb.addExchanger(makeAddr("ex1"));
        funder.setTradingWallet(address(disb));
        _register(leader, owner);
        _activate(leader, 0);

        MockMultisig safe = new MockMultisig();
        address ops = makeAddr("ops");
        accounts.addAdmin(ops); // day-to-day admin on a plain wallet, added while the old key still owns

        // accounts: nothing changes until the multisig accepts.
        accounts.transferOwnership(address(safe));
        assertEq(accounts.owner(), owner);
        vm.expectRevert("NOT_PENDING_OWNER");
        vm.prank(ops);
        accounts.acceptOwnership();
        safe.exec(address(accounts), abi.encodeWithSignature("acceptOwnership()"));
        assertEq(accounts.owner(), address(safe));
        assertEq(accounts.pendingOwner(), address(0));
        assertEq(accounts.root(), owner); // root never moves
        assertTrue(accounts.checkIsAdmin(address(safe)));
        assertFalse(accounts.checkIsAdmin(owner)); // the old key is no longer owner or admin
        assertTrue(accounts.checkIsAdmin(ops));

        // liquidity and the exchanger: single-step, so the address must be right the first time.
        lp.transferOwnership(address(safe));
        disb.transferOwnership(address(safe));
        assertEq(lp.owner(), address(safe));
        assertEq(disb.owner(), address(safe));

        // The old key has lost every owner power.
        vm.expectRevert("NOT_OWNER");
        funder.setTradingWallet(trading);
        vm.expectRevert("NOT_AUTH");
        funder.sendToTrading(1 ether);
        vm.expectRevert("NOT_OWNER");
        gateway.lockFunder();
        vm.expectRevert("NOT_AUTH");
        gateway.setPaused(true);
        vm.expectRevert("NOT_OWNER");
        vesting.withdrawUnreserved(owner, 1 ether);
        vm.expectRevert("NOT_OWNER");
        lp.emergencyWithdraw();
        vm.expectRevert();
        disb.addExchanger(makeAddr("ex2"));

        // Members carry on: register under root, deposit, activate, claim, withdraw.
        _register(sponsor, owner);
        _activate(sponsor, 0);
        _register(alice, sponsor);
        _activate(alice, 0);
        _deposit(alice, 120 ether); // 100 for the next tier, 20 to withdraw
        _activate(alice, 1);
        vm.warp(JAN_15_2027 + DAY + 1);
        vm.prank(alice);
        rewards.claimDaily();
        uint256 cash = usdt.balanceOf(alice);
        vm.prank(alice);
        gateway.withdraw(20 ether);
        assertGt(usdt.balanceOf(alice), cash);

        // The ops admin still runs admin tasks, including sendToTrading (owner 2026-11-09), but no owner task.
        vm.prank(ops);
        funder.sendToTrading(1 ether);
        vm.prank(ops);
        gateway.setPaused(true);
        vm.prank(ops);
        gateway.setPaused(false);
        vm.prank(ops);
        vm.expectRevert("NOT_OWNER");
        funder.addFundingWallet(makeAddr("fw"));

        // Every owner call works through the multisig.
        safe.exec(address(funder), abi.encodeCall(ZyqorixFunder.addFundingWallet, (makeAddr("fw"))));
        uint256 out = funder.tradingCapitalOut();
        safe.exec(address(funder), abi.encodeCall(ZyqorixFunder.sendToTrading, (1 ether)));
        assertEq(funder.tradingCapitalOut(), out + 1 ether);
        safe.exec(address(rewards), abi.encodeCall(ZyqorixRewards.setAgent, (leader, true)));
        assertTrue(rewards.isAgent(leader));
        safe.exec(address(vesting), abi.encodeCall(ZyqorixVesting.withdrawUnreserved, (address(safe), 1 ether)));
        assertEq(zqr.balanceOf(address(safe)), 1 ether); // ZQR lands in the multisig with no receive()
        safe.exec(address(disb), abi.encodeCall(ExchangerDisbursement.addExchanger, (makeAddr("ex2"))));
        assertEq(disb.exchangerCount(), 2);
        safe.exec(address(lp), abi.encodeCall(ZyqorixLiquidity.collectFees, ()));
        // Launch locks can also be done after the handover, in the runbook order (11.1 then 11.2).
        safe.exec(address(lp), abi.encodeCall(ZyqorixLiquidity.lockLiquidity, ()));
        safe.exec(address(gateway), abi.encodeCall(ZyqorixGateway.lockFunder, ()));
        assertTrue(gateway.funderLocked());
    }

    /// @dev Cancelling or re-pointing a pending handover: the owner can overwrite the pending address.
    function test_pendingOwnerCanBeReplacedBeforeAccept() public {
        MockMultisig wrong = new MockMultisig();
        MockMultisig right = new MockMultisig();
        accounts.transferOwnership(address(wrong));
        accounts.transferOwnership(address(right));
        vm.expectRevert("NOT_PENDING_OWNER");
        wrong.exec(address(accounts), abi.encodeWithSignature("acceptOwnership()"));
        right.exec(address(accounts), abi.encodeWithSignature("acceptOwnership()"));
        assertEq(accounts.owner(), address(right));
    }
}
