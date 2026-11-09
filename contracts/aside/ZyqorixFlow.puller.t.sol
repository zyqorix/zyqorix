// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test, stdStorage, StdStorage} from "forge-std/Test.sol";
import {ZyqorixAccounts} from "../accounts.sol";
import {ExchangerDisbursement} from "../exchangerdisbursement.sol";
import {ZyqorixFunder} from "../funder.sol";
import {ZyqorixFundingPuller} from "../fundingpuller.sol";
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
/// @dev A puller whose pull always reverts, to prove a broken puller can't block a withdrawal.
contract RevertingPuller {
    address public gateway;
    constructor(address gatewayAddr) { gateway = gatewayAddr; }
    function pull() external pure returns (uint256) { revert("PULL_BROKEN"); }
    function pending() external pure returns (uint256) { revert("PENDING_BROKEN"); }
}

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
        assertEq(usdt.balanceOf(trading), 45 ether); // 30% of 150
        assertEq(usdt.balanceOf(address(funder)), 100_105 ether); // the liquidity share stayed here
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

    /// @dev A freshly deployed funder from the same build: migrateFunder does all of its wiring.
    function _nextFunder() internal returns (ZyqorixFunder next) {
        next = new ZyqorixFunder(address(accounts));
    }

    function test_migrateFunderMovesTheMoneyAndTheLedger() public {
        _register(sponsor, owner);
        _activate(sponsor, 0);
        _register(alice, sponsor);
        _activate(alice, 0);
        vm.warp(JAN_15_2027 + 2 * DAY);

        uint256 balance = usdt.balanceOf(address(funder));
        uint256 pool = funder.rewardPool();
        assertEq(funder.tradingCapitalOut(), 30 ether);

        ZyqorixFunder next = _nextFunder();
        gateway.migrateFunder(address(next)); // one transaction, nothing set on `next` beforehand

        assertEq(address(gateway.funder()), address(next));
        assertEq(next.gateway(), address(gateway));
        assertEq(next.rewards(), address(rewards));
        assertEq(next.tradingWallet(), trading);
        assertEq(usdt.balanceOf(address(funder)), 0);
        assertEq(usdt.balanceOf(address(next)), balance);
        assertEq(next.rewardPool(), pool);
        assertEq(next.tradingCapitalOut(), 30 ether);
        assertTrue(funder.isSealed());
        assertEq(funder.migratedTo(), address(next));

        // Claims, deposits, withdrawals and activations all carry on against the new funder.
        vm.prank(alice);
        assertEq(rewards.claimDaily(), 1 ether);
        assertEq(next.rewardPool(), pool); // reward credit, drawn when it leaves the wallet

        _deposit(alice, 119 ether);
        assertEq(usdt.balanceOf(address(next)), balance + 119 ether);
        _activate(alice, 1);
        assertEq(next.tradingCapitalOut(), 60 ether);

        vm.warp(JAN_15_2027 + 4 * DAY);
        uint256 cash = usdt.balanceOf(alice);
        vm.prank(alice);
        gateway.withdraw(20 ether); // 19 of deposit and the 1 of reward credit, drawn from the new funder's pool
        assertEq(usdt.balanceOf(alice), cash + 18 ether);
        assertEq(next.rewardPool(), pool - 1 ether);

        // Capital still comes back first: $60 is outstanding, so only the rest is profit.
        usdt.mint(trading, 5 ether); // $5 of trading profit on top of the $60 it was sent
        vm.startPrank(trading);
        usdt.approve(address(next), 65 ether);
        next.fundRewards(65 ether);
        vm.stopPrank();
        assertEq(next.tradingCapitalReturned(), 60 ether);
        assertEq(next.rewardPool(), pool - 1 ether + 5 ether);
    }

    /// @dev Once sealed, the old funder takes no money and changes no ledger, so nothing can strand there.
    function test_oldFunderIsSealedAfterMigrating() public {
        gateway.migrateFunder(address(_nextFunder()));
        vm.startPrank(trading);
        usdt.mint(trading, 10 ether);
        usdt.approve(address(funder), 10 ether);
        vm.expectRevert("MIGRATED");
        funder.fundRewards(10 ether);
        vm.stopPrank();

        vm.prank(address(gateway));
        vm.expectRevert("MIGRATED");
        funder.pay(alice, 1);
        vm.startPrank(address(rewards));
        vm.expectRevert("MIGRATED");
        funder.drawRewardPool(1);
        vm.expectRevert("MIGRATED");
        funder.sendToTrading(1);
        vm.stopPrank();
        vm.expectRevert("MIGRATED");
        funder.redeployCapital(0);
        vm.expectRevert("MIGRATED");
        funder.setTradingWallet(alice);

        vm.expectRevert("MIGRATED"); // going back: the sealed funder can't adopt again
        gateway.migrateFunder(address(funder));
    }

    /// @dev The sealed funder drops its gateway link, so an admin's setFunder can't point deposits back at it.
    function test_setFunderCannotReturnToASealedFunder() public {
        ZyqorixFunder next = _nextFunder();
        gateway.migrateFunder(address(next));
        assertEq(funder.gateway(), address(0));
        vm.expectRevert("FUNDER_NOT_LINKED");
        gateway.setFunder(address(funder));
        vm.expectRevert("MIGRATED");
        funder.setGateway(address(gateway));
        assertEq(address(gateway.funder()), address(next));
    }

    /// @dev A sealed funder can't be relinked to a gateway or rewards contract, so it can never be revived.
    function test_sealedFunderRefusesRelinks() public {
        gateway.migrateFunder(address(_nextFunder()));
        vm.expectRevert("MIGRATED");
        funder.setRewards(address(this));
        vm.expectRevert("MIGRATED");
        funder.setGateway(address(this));
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
        assertEq(funder.rewardPool(), pool - 10 ether);
    }

    /// @dev USDT sent to the old address by mistake isn't stuck: anyone can forward it to the replacement.
    function test_lateUsdtOnASealedFunderIsForwarded() public {
        vm.expectRevert("NOT_MIGRATED");
        funder.forward();

        ZyqorixFunder next = _nextFunder();
        gateway.migrateFunder(address(next));
        uint256 before = usdt.balanceOf(address(next));
        uint256 pool = next.rewardPool();
        usdt.mint(address(funder), 7 ether); // a plain transfer to the old address
        vm.prank(alice);
        assertEq(funder.forward(), 7 ether);
        assertEq(usdt.balanceOf(address(funder)), 0);
        assertEq(usdt.balanceOf(address(next)), before + 7 ether);
        assertEq(next.rewardPool(), pool); // surplus, not profit
    }

    /// @dev The reward pool and every member's reward credit carry across a migration unchanged.
    function test_rewardLedgerHoldsAcrossMigration() public {
        _register(sponsor, owner);
        _activate(sponsor, 0);
        _register(alice, sponsor);
        _activate(alice, 0);
        vm.warp(JAN_15_2027 + 3 * DAY);
        vm.prank(alice);
        rewards.claimDaily();

        uint256 pool = funder.rewardPool();
        uint256 credit = rewards.rewardCredit(alice);
        assertGt(credit, 0);
        ZyqorixFunder next = _nextFunder();
        gateway.migrateFunder(address(next));
        assertEq(next.rewardPool(), pool);
        assertEq(rewards.rewardCredit(alice), credit);
        assertEq(rewards.totalRewardCredit(), credit + rewards.rewardCredit(sponsor));
        assertEq(rewards.withdrawable(alice), rewards.walletBalance(alice)); // the pool covers the credit
    }

    function test_migrateFunderRepeatsAToBToC() public {
        _register(alice, owner);
        _activate(alice, 0);
        uint256 balance = usdt.balanceOf(address(funder));
        uint256 pool = funder.rewardPool();

        ZyqorixFunder b = _nextFunder();
        gateway.migrateFunder(address(b));
        ZyqorixFunder c = _nextFunder();
        gateway.migrateFunder(address(c));

        assertEq(address(gateway.funder()), address(c));
        assertTrue(b.isSealed());
        assertEq(usdt.balanceOf(address(b)), 0);
        assertEq(usdt.balanceOf(address(c)), balance);
        assertEq(c.rewardPool(), pool);
        assertEq(c.tradingCapitalOut(), 15 ether); // 30% of one $50 activation
        assertEq(c.tradingWallet(), trading);
    }

    function test_migrateFunderGates() public {
        ZyqorixFunder next = _nextFunder();

        vm.prank(alice);
        vm.expectRevert("NOT_OWNER");
        gateway.migrateFunder(address(next));

        vm.expectRevert("SAME_FUNDER");
        gateway.migrateFunder(address(funder));

        vm.expectRevert("NOT_CONTRACT");
        gateway.migrateFunder(alice);

        vm.expectRevert("CODE_MISMATCH"); // any other contract, however it looks
        gateway.migrateFunder(address(rewards));

        ZyqorixAccounts otherAccounts = new ZyqorixAccounts();
        ZyqorixFunder otherBuild = new ZyqorixFunder(address(otherAccounts));
        vm.expectRevert("CODE_MISMATCH"); // same source, different accounts contract
        gateway.migrateFunder(address(otherBuild));

        ZyqorixFunder wired = _nextFunder();
        wired.setGateway(address(gateway));
        vm.expectRevert("ALREADY_SET"); // only a fresh funder can be adopted
        gateway.migrateFunder(address(wired));

        assertEq(address(gateway.funder()), address(funder)); // failed attempts change nothing
        assertFalse(funder.isSealed());
    }

    /// @dev Only the gateway's live funder, with this exact code, can wire a fresh funder.
    function test_adoptOnlyFromTheLiveFunder() public {
        ZyqorixFunder next = _nextFunder();

        vm.prank(alice);
        vm.expectRevert("CODE_MISMATCH");
        next.adopt(address(gateway), address(rewards), trading, 0, 0, 0, 1 ether);

        ZyqorixFunder idle = _nextFunder(); // same code, linked to the gateway, but not its live funder
        idle.setGateway(address(gateway));
        vm.prank(address(idle));
        vm.expectRevert("NOT_LIVE_FUNDER");
        next.adopt(address(gateway), address(rewards), trading, 0, 0, 0, 1 ether);

        vm.prank(alice);
        vm.expectRevert("NOT_GATEWAY");
        funder.migrateTo(address(next));
    }

    function test_lockFunderClosesMigrationForGood() public {
        _mintPosition();
        lp.lockLiquidity();
        gateway.lockFunder();
        ZyqorixFunder next = _nextFunder();
        vm.expectRevert("FUNDER_LOCKED");
        gateway.migrateFunder(address(next));
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
        vm.warp(JAN_15_2027 + 120 * DAY);
        for (uint256 tier = 0; tier < 5; tier++) _activate(alice, tier);
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

    /* ----------------------------- Funding puller ----------------------------- */
    address fundingWallet = makeAddr("fundingWallet");

    function _puller() internal returns (ZyqorixFundingPuller puller) {
        puller = new ZyqorixFundingPuller(address(accounts), address(gateway));
        puller.addFundingWallet(fundingWallet);
        rewards.setFundingPuller(address(puller));
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
        ZyqorixFundingPuller puller = new ZyqorixFundingPuller(address(accounts), address(gateway));
        usdt.mint(fundingWallet, 30 ether);
        assertEq(puller.pending(), 0); // no funding wallet set
        assertEq(puller.pull(), 0);
        puller.addFundingWallet(fundingWallet);
        assertEq(puller.pending(), 0); // not approved yet
        vm.prank(fundingWallet);
        usdt.approve(address(puller), 20 ether);
        assertEq(puller.pending(), 20 ether);
        vm.prank(fundingWallet);
        usdt.approve(address(puller), type(uint256).max);
        assertEq(puller.pending(), 30 ether);
        vm.prank(fundingWallet);
        usdt.approve(address(puller), 0); // revoked
        assertEq(puller.pending(), 0);
        assertEq(puller.pull(), 0);
        assertEq(usdt.balanceOf(fundingWallet), 30 ether);
    }

    /// @dev A pull is booked exactly like fundRewards: outstanding trading capital first, then the pool.
    function test_pullBooksCapitalFirstThenThePool() public {
        ZyqorixFundingPuller puller = _puller();
        stdstore.target(address(funder)).sig("rewardPool()").checked_write(uint256(0));
        _register(alice, owner);
        _activate(alice, 0); // 30% (15 USDT) leaves as trading capital
        uint256 owed = funder.tradingCapitalOut() - funder.tradingCapitalReturned();
        assertEq(owed, 15 ether);

        usdt.mint(fundingWallet, 30 ether);
        vm.prank(fundingWallet);
        usdt.approve(address(puller), type(uint256).max);
        uint256 held = usdt.balanceOf(address(funder));
        vm.prank(alice); // anyone can trigger it
        assertEq(puller.pull(), 30 ether);
        assertEq(usdt.balanceOf(fundingWallet), 0);
        assertEq(usdt.balanceOf(address(puller)), 0);
        assertEq(usdt.balanceOf(address(funder)), held + 30 ether);
        assertEq(funder.rewardPool(), 15 ether);
        assertEq(funder.tradingCapitalReturned(), 15 ether);
        assertEq(usdt.allowance(address(puller), address(funder)), 0);
    }

    function test_pullerAdminIsOwnerOnlyAndKeepsUsdt() public {
        ZyqorixFundingPuller puller = _puller();
        vm.prank(alice);
        vm.expectRevert("NOT_OWNER");
        puller.addFundingWallet(alice);
        vm.prank(alice);
        vm.expectRevert("NOT_OWNER");
        rewards.setFundingPuller(address(0));
        vm.expectRevert("NOT_CONTRACT");
        rewards.setFundingPuller(alice);
        address unlinked = address(new RevertingPuller(alice));
        vm.expectRevert("PULLER_NOT_LINKED");
        rewards.setFundingPuller(unlinked);

        usdt.mint(address(puller), 3 ether);
        vm.expectRevert("PAYMENT_TOKEN_LOCKED");
        puller.recoverToken(address(usdt), owner, 3 ether);
        zqr.mint(address(puller), 4 ether);
        puller.recoverToken(address(zqr), alice, 4 ether);
        assertEq(zqr.balanceOf(alice), 4 ether);
    }

    /// @dev The withdrawal that needs the pool pulls the funding wallet in first, with no other transaction.
    function test_pullerWalletListIsOwnerManagedAndBounded() public {
        ZyqorixFundingPuller puller = _puller();
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

    /// @dev Every approved wallet is pulled into one fundRewards; an unapproved one is skipped; a removed one is left.
    function test_pullSumsEveryFundingWallet() public {
        ZyqorixFundingPuller puller = _puller();
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
        assertEq(puller.pending(), 50 ether);

        uint256 pool = funder.rewardPool();
        vm.expectEmit(true, true, false, true, address(puller));
        emit ZyqorixFundingPuller.FundingPulled(fundingWallet, address(funder), 10 ether);
        vm.expectEmit(true, true, false, true, address(puller));
        emit ZyqorixFundingPuller.FundingPulled(second, address(funder), 40 ether);
        assertEq(puller.pull(), 50 ether);
        assertEq(funder.rewardPool(), pool + 50 ether);
        assertEq(usdt.balanceOf(fundingWallet), 20 ether);
        assertEq(usdt.balanceOf(second), 0);
        assertEq(usdt.balanceOf(third), 50 ether);

        puller.removeFundingWallet(fundingWallet);
        assertEq(puller.pending(), 0); // its remaining 10 approval no longer counts
        assertEq(puller.pull(), 0);
        assertEq(usdt.balanceOf(fundingWallet), 20 ether);
    }

    function test_withdrawalAutoPullsAcrossWallets() public {
        _aliceWithCreditAndEmptyPool();
        ZyqorixFundingPuller puller = _puller();
        address second = makeAddr("second");
        puller.addFundingWallet(second);
        uint256 owed = funder.tradingCapitalOut() - funder.tradingCapitalReturned();
        usdt.mint(fundingWallet, owed); // just repays the capital
        usdt.mint(second, 10 ether); // covers the credit
        vm.prank(fundingWallet);
        usdt.approve(address(puller), type(uint256).max);
        vm.prank(second);
        usdt.approve(address(puller), type(uint256).max);
        assertEq(rewards.withdrawable(alice), 60 ether);

        vm.prank(alice);
        gateway.withdraw(60 ether);
        assertEq(usdt.balanceOf(fundingWallet), 0);
        assertEq(usdt.balanceOf(second), 0);
        assertEq(funder.rewardPool(), 0);
        assertEq(rewards.rewardCredit(alice), 0);
    }

    /// @dev A wallet whose transferFrom fails is skipped; the others are still booked.
    function test_pullSkipsAFailingWallet() public {
        ZyqorixFundingPuller puller = _puller();
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
        assertEq(puller.pull(), 40 ether);
        assertEq(funder.rewardPool(), pool + 40 ether);
        assertEq(usdt.balanceOf(fundingWallet), 30 ether);
        assertEq(usdt.balanceOf(second), 0);
    }

    /// @dev USDT sent to the puller directly isn't stuck: the next pull books it.
    function test_pullBooksUsdtSentDirectly() public {
        ZyqorixFundingPuller puller = _puller();
        usdt.mint(address(puller), 7 ether);
        assertEq(puller.pending(), 7 ether);
        uint256 pool = funder.rewardPool();
        assertEq(puller.pull(), 7 ether);
        assertEq(funder.rewardPool(), pool + 7 ether);
        assertEq(usdt.balanceOf(address(puller)), 0);
    }

    /// @dev The worst case for a withdrawal: all five wallets pulled. Measures the gas the app has to cover.
    function test_withdrawalPullingFiveWalletsGas() public {
        _aliceWithCreditAndEmptyPool();
        ZyqorixFundingPuller puller = _puller();
        uint256 owed = funder.tradingCapitalOut() - funder.tradingCapitalReturned();
        for (uint256 i = 0; i < 5; i++) {
            address wallet = i == 0 ? fundingWallet : makeAddr(string(abi.encode("w", i)));
            if (i > 0) puller.addFundingWallet(wallet);
            usdt.mint(wallet, (owed + 10 ether) / 5 + 1 ether);
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
        ZyqorixFundingPuller puller = _puller();
        usdt.mint(fundingWallet, 30 ether);
        assertEq(rewards.withdrawable(alice), 50 ether); // not approved: only the deposit part

        vm.prank(alice);
        vm.expectRevert("INSUFFICIENT_REWARD_POOL");
        gateway.withdraw(60 ether);
        assertEq(usdt.balanceOf(fundingWallet), 30 ether); // the revert undid the pull too

        vm.prank(fundingWallet);
        usdt.approve(address(puller), type(uint256).max);
        // 30 waiting, 15 repays trading capital first, so 15 more is coverable: all 10 of the credit.
        assertEq(rewards.withdrawable(alice), 60 ether);
        uint256 before = usdt.balanceOf(alice);
        vm.prank(alice);
        gateway.withdraw(60 ether);
        assertEq(usdt.balanceOf(alice), before + 54 ether); // 10% fee
        assertEq(usdt.balanceOf(fundingWallet), 0);
        assertEq(funder.rewardPool(), 5 ether); // 15 booked, 10 drawn
        assertEq(rewards.rewardCredit(alice), 0);
    }

    /// @dev A withdrawal the pool already covers never touches the funding wallet.
    function test_noPullWhileThePoolCovers() public {
        ZyqorixFundingPuller puller = _puller();
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

    function test_brokenPullerNeverBlocksAWithdrawal() public {
        _aliceWithCreditAndEmptyPool();
        rewards.setFundingPuller(address(new RevertingPuller(address(gateway))));
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

        ZyqorixFundingPuller puller = _puller();
        usdt.mint(fundingWallet, 100 ether);
        vm.prank(fundingWallet);
        usdt.approve(address(puller), type(uint256).max);
        _activate(alice, 1);
        assertEq(usdt.balanceOf(fundingWallet), 0);
        assertEq(rewards.rewardCredit(alice), 0);
        assertEq(funder.rewardPool(), 55 ether); // 100 - 15 trading capital - 30 drawn
    }
}
