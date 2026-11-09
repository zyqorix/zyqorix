// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {ZyqorixAccounts} from "../accounts.sol";
import {ZyqorixFunder} from "../funder.sol";
import {ZyqorixGateway} from "../gateway.sol";

contract MockToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public feeBps;

    function mint(address to, uint256 v) external { balanceOf[to] += v; }
    function setFee(uint256 bps) external { feeBps = bps; }
    function approve(address s, uint256 v) external returns (bool) { allowance[msg.sender][s] = v; return true; }

    function transfer(address to, uint256 v) external returns (bool) {
        balanceOf[msg.sender] -= v;
        balanceOf[to] += v;
        return true;
    }

    function transferFrom(address f, address to, uint256 v) external returns (bool) {
        allowance[f][msg.sender] -= v;
        balanceOf[f] -= v;
        balanceOf[to] += v - (v * feeBps) / 10_000;
        return true;
    }
}

/// @dev Stands in for the rewards contract's balance records.
contract MockRewards {
    mapping(address => uint256) public walletBalance;
    mapping(address => uint256) public agentBalance;
    mapping(address => bool) public isAgent;
    bool public reenter;
    address public gateway;

    function setGateway(address p) external { gateway = p; }
    function setBalance(address u, uint256 v) external { walletBalance[u] = v; }
    function setAgent(address u, uint256 v) external { agentBalance[u] = v; isAgent[u] = true; }
    function removeAgent(address u) external { isAgent[u] = false; }
    function setReenter(bool v) external { reenter = v; }

    function creditDeposit(address user, uint256 amount) external {
        require(msg.sender == gateway, "NOT_GATEWAY");
        walletBalance[user] += amount;
    }

    function debitWallet(address user, uint256 amount) external {
        require(msg.sender == gateway, "NOT_GATEWAY");
        walletBalance[user] -= amount;
        if (reenter) ZyqorixGateway(msg.sender).withdraw(amount);
    }

    function debitAgent(address user, uint256 amount) external {
        require(msg.sender == gateway, "NOT_GATEWAY");
        agentBalance[user] -= amount;
    }

    uint256 public profit;
    function notifyProfit(uint256 amount) external { profit += amount; }
}

/// @dev Burnable token bought with the fee.
contract MockSwapToken is MockToken {
    bool public burnBlocked;
    function setBurnBlocked(bool v) external { burnBlocked = v; }
    function burn(uint256 v) external {
        require(!burnBlocked, "BURN_BLOCKED");
        balanceOf[msg.sender] -= v;
    }
}

/// @dev Token with no burn function at all.
contract MockPlainToken is MockToken {}

/// @dev Stands in for the liquidity contract: pulls the fee and pays out the token 2:1.
contract MockLiquidity {
    address public USDT;
    address public TOKEN;
    uint8 public mode; // 0 = swaps, 1 = returns 0, 2 = reverts, 3 = runs out of gas
    uint256 public lastSlippage;
    uint256 public lastOut;
    bool public liquidityLocked;
    uint256 public TOKENID = 1;

    constructor(address usdt, address tok) { USDT = usdt; TOKEN = tok; }
    function setTokenId(uint256 v) external { TOKENID = v; }
    function setMode(uint8 m) external { mode = m; }
    function setLocked(bool v) external { liquidityLocked = v; }

    function swapUSDTToToken(uint256 amount, uint24 slippageBps, address recipient, uint256) external returns (uint256) {
        require(mode != 2, "SWAP_FAILED");
        if (mode == 3) while (true) {}
        MockToken(USDT).transferFrom(msg.sender, address(this), amount);
        if (mode == 1) return 0;
        lastSlippage = slippageBps;
        lastOut = amount * 2;
        MockToken(TOKEN).mint(recipient, lastOut);
        return lastOut;
    }
}

/// @dev A funder that pays out some other token, for the FUNDER_TOKEN_MISMATCH check.
contract OtherTokenFunder {
    function token() external pure returns (address) { return address(0xBEEF); }
}

contract ZyqorixGatewayTest is Test {
    /// @dev USDT's BSC mainnet address, hardcoded in funder, gateway, liquidity and the exchanger.
    address constant USDT_ADDR = 0x55d398326f99059fF775485246999027B3197955;
    uint256 constant START = 1_000_000;
    uint256 constant DAY = 1 days;

    ZyqorixAccounts accounts;
    ZyqorixFunder funder;
    ZyqorixGateway gateway;
    MockToken usdt;
    MockRewards rewards;
    MockLiquidity liquidity;
    MockSwapToken zyq;

    address owner = address(this);
    address hub = makeAddr("hub");
    address alice = makeAddr("alice");
    address stranger = makeAddr("stranger");

    function setUp() public {
        vm.warp(START);
        // USDT's mainnet address is hardcoded in the contracts: etch the mock there.
        vm.etch(USDT_ADDR, type(MockToken).runtimeCode);
        usdt = MockToken(USDT_ADDR);
        accounts = new ZyqorixAccounts();
        accounts.addAdmin(hub);
        accounts.addUser(alice, owner);

        funder = new ZyqorixFunder(address(accounts));
        gateway = new ZyqorixGateway(address(accounts), address(funder));
        funder.setGateway(address(gateway));

        rewards = new MockRewards();
        rewards.setGateway(address(gateway));
        gateway.setRewards(address(rewards));

        zyq = new MockSwapToken();
        liquidity = new MockLiquidity(address(usdt), address(zyq));
        gateway.setLiquidity(address(liquidity));
        gateway.setMinDeposit(0); // these tests size deposits freely; ZyqorixFlow tests the minimum
        gateway.setWithdrawalLimits(10 ether, 100 ether, 10 ether); // lets these tests withdraw 50; the default rule is tested below

        usdt.mint(alice, 1_000 ether);
        vm.prank(alice);
        usdt.approve(address(gateway), type(uint256).max);
    }

    function _funded(uint256 funderBal, uint256 rewardsBal) internal {
        usdt.mint(address(funder), funderBal);
        rewards.setBalance(alice, rewardsBal);
    }

    function _newFunder() internal returns (ZyqorixFunder f) {
        f = new ZyqorixFunder(address(accounts));
        f.setGateway(address(gateway));
    }

    /* ---------------------------- Deposits ---------------------------- */
    function test_depositGoesToFunderAndGatewayStaysEmpty() public {
        vm.prank(alice);
        gateway.deposit(address(usdt), 100 ether);

        assertEq(usdt.balanceOf(address(gateway)), 0);
        assertEq(usdt.balanceOf(address(funder)), 100 ether);
        assertEq(rewards.walletBalance(alice), 100 ether);
    }

    function test_depositCreditsActualAmountReceived() public {
        usdt.setFee(100); // 1%
        vm.prank(alice);
        gateway.deposit(address(usdt), 100 ether);
        assertEq(rewards.walletBalance(alice), 99 ether);
        assertEq(usdt.balanceOf(address(funder)), 99 ether);
    }

    function test_depositGates() public {
        vm.prank(stranger);
        vm.expectRevert("NOT_REGISTERED");
        gateway.deposit(address(usdt), 1 ether);

        vm.prank(alice);
        vm.expectRevert("ZERO_AMOUNT");
        gateway.deposit(address(usdt), 0);

        gateway.setPaused(true);
        vm.prank(alice);
        vm.expectRevert("PAUSED");
        gateway.deposit(address(usdt), 1 ether);
    }

    function test_depositRejectsAnyOtherToken() public {
        MockToken fake = new MockToken();
        fake.mint(alice, 100 ether);
        vm.startPrank(alice);
        fake.approve(address(gateway), 100 ether);
        vm.expectRevert("BAD_TOKEN");
        gateway.deposit(address(fake), 100 ether);
        vm.stopPrank();

        vm.prank(hub);
        vm.expectRevert("BAD_TOKEN");
        gateway.depositFor(alice, address(fake), 100 ether);
        assertEq(rewards.walletBalance(alice), 0);
    }

    /// @dev Owner 2026-11-06: depositTo was removed (unused, and it let anyone restart a member's cooldown).
    function test_depositToIsGone() public {
        usdt.mint(stranger, 100 ether);
        vm.startPrank(stranger);
        usdt.approve(address(gateway), 100 ether);
        (bool ok, ) = address(gateway).call(
            abi.encodeWithSignature("depositTo(address,address,uint256)", alice, address(usdt), 100 ether)
        );
        vm.stopPrank();
        assertFalse(ok);
        assertEq(rewards.walletBalance(alice), 0);
        assertEq(gateway.coolDown(alice), 0);
    }

    function test_depositForIsAuthOnly() public {
        vm.prank(stranger);
        vm.expectRevert("NOT_AUTH");
        gateway.depositFor(alice, address(usdt), 10 ether);

        vm.prank(hub);
        gateway.depositFor(alice, address(usdt), 10 ether);
        assertEq(rewards.walletBalance(alice), 10 ether);
    }

    /* --------------------------- Withdrawals -------------------------- */
    function test_withdrawPaysFromFunderAndDebitsRewards() public {
        _funded(500 ether, 100 ether);
        vm.prank(alice);
        gateway.withdraw(50 ether);

        assertEq(usdt.balanceOf(alice), 1_045 ether);
        assertEq(usdt.balanceOf(address(liquidity)), 5 ether);
        assertEq(usdt.balanceOf(address(funder)), 450 ether);
        assertEq(usdt.balanceOf(address(gateway)), 0);
        assertEq(usdt.allowance(address(gateway), address(liquidity)), 0);
        assertEq(liquidity.lastSlippage(), 300);
        assertEq(liquidity.lastOut(), 10 ether); // bought with the 5 fee
        assertEq(zyq.balanceOf(address(gateway)), 0); // burned
        assertEq(rewards.walletBalance(alice), 50 ether);
    }

    /// @dev A gas limit too small for the fee swap reverts the whole withdrawal instead of skipping the burn, so a
    ///      wallet's gas estimate always covers the swap.
    function test_withdrawWithTooLittleGasForTheBurnReverts() public {
        _funded(500 ether, 100 ether);
        vm.prank(alice);
        vm.expectRevert("LOW_GAS_FOR_BURN");
        gateway.withdraw{gas: 300_000}(50 ether);
        assertEq(rewards.walletBalance(alice), 100 ether); // nothing moved

        vm.prank(alice);
        gateway.withdraw{gas: 700_000}(50 ether);
        assertEq(liquidity.lastOut(), 10 ether); // the fee was swapped and burned
    }

    function test_withdrawRevertsWithoutEnoughWallet() public {
        _funded(500 ether, 49 ether);
        vm.prank(alice);
        vm.expectRevert("INSUFFICIENT_WALLET");
        gateway.withdraw(50 ether);
    }

    function test_withdrawRevertsWithoutEnoughFunderBalance() public {
        _funded(49 ether, 100 ether);
        vm.prank(alice);
        vm.expectRevert("INSUFFICIENT_FUNDER");
        gateway.withdraw(50 ether);
    }

    function test_depositCanBeWithdrawnAfterCooldown() public {
        usdt.mint(address(funder), 500 ether);
        vm.startPrank(alice);
        gateway.deposit(address(usdt), 100 ether);
        vm.expectRevert("COOLDOWN");
        gateway.withdraw(100 ether);

        vm.warp(START + DAY + 1);
        gateway.withdraw(100 ether);
        vm.stopPrank();
        assertEq(usdt.balanceOf(alice), 990 ether); // 1000 - 100 + 90
    }

    function test_depositResetsCooldown() public {
        _funded(500 ether, 200 ether);
        vm.prank(alice);
        gateway.withdraw(50 ether);

        vm.warp(START + DAY - 10);
        vm.prank(alice);
        gateway.deposit(address(usdt), 1 ether); // restarts 24h from here

        vm.warp(START + DAY + 1);
        vm.prank(alice);
        vm.expectRevert("COOLDOWN");
        gateway.withdraw(50 ether);

        vm.warp(START + DAY + DAY);
        vm.prank(alice);
        gateway.withdraw(50 ether);
    }

    function test_agentWithdrawalPaysFullAmountWithCooldown() public {
        usdt.mint(address(funder), 500 ether);
        rewards.setAgent(alice, 33 ether);

        vm.prank(alice);
        gateway.withdrawAgent(33 ether); // any amount, no fee

        assertEq(usdt.balanceOf(alice), 1_033 ether);
        assertEq(usdt.balanceOf(address(liquidity)), 0);
        assertEq(rewards.agentBalance(alice), 0);

        rewards.setAgent(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert("COOLDOWN");
        gateway.withdrawAgent(10 ether);
    }

    function test_agentWithdrawalGates() public {
        rewards.setAgent(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert("INSUFFICIENT_FUNDER");
        gateway.withdrawAgent(10 ether);

        usdt.mint(address(funder), 100 ether);
        vm.prank(alice);
        vm.expectRevert("INSUFFICIENT_AGENT");
        gateway.withdrawAgent(11 ether);

        vm.prank(stranger);
        vm.expectRevert("NOT_REGISTERED");
        gateway.withdrawAgent(1 ether);
    }

    function test_removedAgentCannotWithdrawUntilNominatedAgain() public {
        usdt.mint(address(funder), 100 ether);
        rewards.setAgent(alice, 10 ether);
        rewards.removeAgent(alice);

        vm.prank(alice);
        vm.expectRevert("NOT_AGENT");
        gateway.withdrawAgent(10 ether);
        assertEq(rewards.agentBalance(alice), 10 ether); // the balance is kept

        rewards.setAgent(alice, 10 ether);
        vm.prank(alice);
        gateway.withdrawAgent(10 ether);
        assertEq(usdt.balanceOf(alice), 1_010 ether);
    }

    function test_lockFunderNeedsLockedLiquidity() public {
        vm.expectRevert("LIQUIDITY_NOT_LOCKED");
        gateway.lockFunder();

        gateway.setLiquidity(address(0));
        vm.expectRevert("LIQUIDITY_NOT_LOCKED");
        gateway.lockFunder();
    }

    function test_lockFunderFixesFunderAndLiquidityForGood() public {
        ZyqorixFunder next = _newFunder();
        liquidity.setLocked(true);
        vm.prank(hub);
        vm.expectRevert("NOT_OWNER");
        gateway.lockFunder();

        gateway.lockFunder();
        vm.expectRevert("FUNDER_LOCKED");
        gateway.setFunder(address(next));
        vm.expectRevert("FUNDER_LOCKED");
        gateway.setLiquidity(address(0));
        assertEq(gateway.liquidity(), address(liquidity));
    }

    /// @dev Owner rule: 20 to 100 USDT in multiples of 20 by default, adjustable later (e.g. max 200).
    function test_defaultWithdrawalRuleIs20To100InStepsOf20() public {
        ZyqorixGateway fresh = new ZyqorixGateway(address(accounts), address(funder));
        assertEq(fresh.withdrawalMin(), 20 ether);
        assertEq(fresh.withdrawalMax(), 100 ether);
        assertEq(fresh.withdrawalStep(), 20 ether);
        uint256[5] memory ok = [uint256(20 ether), 40 ether, 60 ether, 80 ether, 100 ether];
        for (uint256 i = 0; i < 5; i++) assertTrue(fresh.isAllowedWithdrawal(ok[i]));
        uint256[7] memory bad = [uint256(0), 10 ether, 19 ether, 50 ether, 99 ether, 120 ether, 20 ether + 1];
        for (uint256 i = 0; i < 7; i++) assertFalse(fresh.isAllowedWithdrawal(bad[i]));
    }

    function test_withdrawEnforcesTheRule() public {
        gateway.setWithdrawalLimits(20 ether, 100 ether, 20 ether);
        _funded(1_000 ether, 500 ether);
        vm.startPrank(alice);
        vm.expectRevert("BAD_WITHDRAWAL_AMOUNT");
        gateway.withdraw(50 ether); // not a multiple of 20
        vm.expectRevert("BAD_WITHDRAWAL_AMOUNT");
        gateway.withdraw(120 ether); // above the max
        gateway.withdraw(60 ether);
        vm.stopPrank();
        assertEq(rewards.walletBalance(alice), 440 ether);
    }

    function test_withdrawForFollowsTheSameRule() public {
        gateway.setWithdrawalLimits(20 ether, 100 ether, 20 ether);
        _funded(1_000 ether, 500 ether);
        vm.prank(hub);
        vm.expectRevert("BAD_WITHDRAWAL_AMOUNT");
        gateway.withdrawFor(alice, 50 ether);
    }

    function test_withdrawalMaxCanBeRaisedTo200() public {
        gateway.setWithdrawalLimits(20 ether, 200 ether, 20 ether);
        _funded(1_000 ether, 500 ether);
        assertTrue(gateway.isAllowedWithdrawal(180 ether));
        vm.prank(alice);
        gateway.withdraw(200 ether);
        assertEq(rewards.walletBalance(alice), 300 ether);
    }

    function test_withdrawalLimitsAreValidatedAndAuthOnly() public {
        vm.expectRevert("BAD_LIMITS");
        gateway.setWithdrawalLimits(20 ether, 100 ether, 0); // no step
        vm.expectRevert("BAD_LIMITS");
        gateway.setWithdrawalLimits(0, 100 ether, 20 ether); // no minimum
        vm.expectRevert("BAD_LIMITS");
        gateway.setWithdrawalLimits(120 ether, 100 ether, 20 ether); // min above max
        vm.expectRevert("BAD_LIMITS");
        gateway.setWithdrawalLimits(30 ether, 100 ether, 20 ether); // min not a multiple
        vm.expectRevert("BAD_LIMITS");
        gateway.setWithdrawalLimits(20 ether, 110 ether, 20 ether); // max not a multiple

        vm.prank(stranger);
        vm.expectRevert("NOT_AUTH");
        gateway.setWithdrawalLimits(20 ether, 200 ether, 20 ether);
    }

    function test_cooldownBlocksSecondWithdrawal() public {
        _funded(500 ether, 200 ether);
        vm.startPrank(alice);
        gateway.withdraw(50 ether);

        vm.warp(START + DAY);
        vm.expectRevert("COOLDOWN");
        gateway.withdraw(50 ether);

        vm.warp(START + DAY + 1);
        gateway.withdraw(50 ether);
        vm.stopPrank();
        assertEq(rewards.walletBalance(alice), 100 ether);
    }

    function test_withdrawalFeeIsConfigurable() public {
        _funded(500 ether, 100 ether);
        vm.prank(stranger);
        vm.expectRevert("NOT_AUTH");
        gateway.setWithdrawalFee(500);
        vm.expectRevert("FEE_TOO_HIGH");
        gateway.setWithdrawalFee(5_001);

        vm.prank(hub);
        gateway.setWithdrawalFee(500); // 5%
        vm.prank(alice);
        gateway.withdraw(100 ether);
        assertEq(usdt.balanceOf(alice), 1_095 ether);
        assertEq(usdt.balanceOf(address(liquidity)), 5 ether);
    }

    function test_zeroFeeSkipsLiquidity() public {
        _funded(500 ether, 100 ether);
        gateway.setWithdrawalFee(0);
        vm.prank(alice);
        gateway.withdraw(100 ether);
        assertEq(usdt.balanceOf(alice), 1_100 ether);
        assertEq(usdt.balanceOf(address(liquidity)), 0);
    }

    function test_failedSwapReturnsFeeToFunder() public {
        for (uint8 mode = 1; mode <= 2; mode++) {
            liquidity.setMode(mode); // 1 = returns 0, 2 = reverts
            address user = makeAddr(mode == 1 ? "u1" : "u2");
            accounts.addUser(user, owner);
            usdt.mint(address(funder), 100 ether);
            uint256 before = usdt.balanceOf(address(funder));
            rewards.setBalance(user, 100 ether);

            vm.prank(user);
            gateway.withdraw(100 ether);

            assertEq(usdt.balanceOf(user), 90 ether);
            assertEq(usdt.balanceOf(address(funder)), before - 90 ether);
            assertEq(usdt.balanceOf(address(gateway)), 0);
            assertEq(usdt.allowance(address(gateway), address(liquidity)), 0);
        }
    }

    /// @dev Owner 2026-11-07: a fee that isn't swapped and burned goes into the reward pool, and the withdrawal
    ///      still pays. Covers a reverting swap, a swap that buys nothing, one that runs out of gas, no position,
    ///      and no liquidity set.
    function test_failedFeeSwapBooksTheFeeIntoThePool() public {
        funder.setRewards(address(rewards));
        for (uint8 c = 0; c < 5; c++) {
            uint256 snap = vm.snapshotState();
            _funded(500 ether, 100 ether);
            if (c < 3) liquidity.setMode(c + 1);
            else if (c == 3) liquidity.setTokenId(0);
            else gateway.setLiquidity(address(0));
            vm.prank(alice);
            gateway.withdraw{gas: 1_100_000}(100 ether);
            assertEq(usdt.balanceOf(alice), 1_090 ether);
            assertEq(funder.rewardPool(), 10 ether);
            assertEq(rewards.profit(), 10 ether);
            assertEq(usdt.balanceOf(address(funder)), 410 ether);
            assertEq(usdt.balanceOf(address(gateway)), 0);
            assertEq(usdt.allowance(address(gateway), address(funder)), 0);
            assertEq(zyq.balanceOf(gateway.BURN_ADDRESS()), 0);
            vm.revertToState(snap);
        }
    }

    /// @dev At the lowest gas the floor allows, a swap that burns all its gas still leaves enough to book the fee.
    function test_outOfGasSwapAtTheFloorStillPays() public {
        funder.setRewards(address(rewards));
        _funded(500 ether, 100 ether);
        liquidity.setMode(3);
        uint256 lowest = 200_000;
        while (true) {
            uint256 snap = vm.snapshotState();
            vm.prank(alice);
            (bool ok, ) = address(gateway).call{gas: lowest}(abi.encodeCall(gateway.withdraw, (100 ether)));
            if (ok) {
                assertEq(funder.rewardPool(), 10 ether);
                assertEq(usdt.balanceOf(alice), 1_090 ether);
                break;
            }
            vm.revertToState(snap);
            lowest += 5_000;
            require(lowest < 1_000_000, "never passed");
        }
        assertLt(lowest, 700_000);
    }

    /// @dev If even booking fails (here the funder has no rewards contract), the fee still lands in the funder.
    function test_noLiquidityReturnsFeeToFunder() public {
        _funded(500 ether, 100 ether);
        vm.prank(hub);
        gateway.setLiquidity(address(0));
        vm.prank(alice);
        gateway.withdraw(100 ether);
        assertEq(usdt.balanceOf(alice), 1_090 ether);
        assertEq(usdt.balanceOf(address(funder)), 410 ether);
        assertEq(usdt.balanceOf(address(gateway)), 0);
    }

    function test_tokenWithoutBurnGoesToDeadAddress() public {
        _funded(500 ether, 100 ether);
        MockPlainToken plain = new MockPlainToken();
        MockLiquidity lp = new MockLiquidity(address(usdt), address(plain));
        gateway.setLiquidity(address(lp));
        vm.prank(alice);
        gateway.withdraw(100 ether);
        assertEq(plain.balanceOf(gateway.BURN_ADDRESS()), 20 ether);
        assertEq(plain.balanceOf(address(gateway)), 0);
    }

    function test_blockedBurnGoesToDeadAddress() public {
        _funded(500 ether, 100 ether);
        zyq.setBurnBlocked(true);
        vm.prank(alice);
        gateway.withdraw(100 ether);
        assertEq(zyq.balanceOf(gateway.BURN_ADDRESS()), 20 ether);
        assertEq(zyq.balanceOf(address(gateway)), 0);
    }

    function test_swapAndBurnFeeIsSelfOnly() public {
        vm.expectRevert("ONLY_SELF");
        gateway.swapAndBurnFee(1 ether);
    }

    function test_setLiquidityGates() public {
        vm.prank(stranger);
        vm.expectRevert("NOT_AUTH");
        gateway.setLiquidity(address(liquidity));
        gateway.setMinDeposit(0); // these tests size deposits freely; ZyqorixFlow tests the minimum

        vm.expectRevert("NOT_CONTRACT");
        gateway.setLiquidity(stranger);
        MockLiquidity wrong = new MockLiquidity(address(new MockToken()), address(zyq));
        vm.expectRevert("LIQUIDITY_TOKEN_MISMATCH");
        gateway.setLiquidity(address(wrong));
    }

    function test_setLiquiditySlippageGates() public {
        vm.expectRevert("SLIPPAGE_TOO_HIGH");
        gateway.setLiquiditySlippage(5_001);
        vm.expectRevert("SLIPPAGE_TOO_LOW"); // below the 1% pool fee every fee swap would fail
        gateway.setLiquiditySlippage(99);
        gateway.setLiquiditySlippage(100);
        assertEq(gateway.liquiditySlippageBps(), 100);
    }

    function test_reentrantWithdrawBlocked() public {
        _funded(500 ether, 100 ether);
        gateway.setWithdrawalCooldown(0);
        rewards.setReenter(true);
        vm.prank(alice);
        vm.expectRevert("REENTRANCY");
        gateway.withdraw(50 ether);
    }

    function test_withdrawForAlwaysPaysTheMember() public {
        _funded(500 ether, 100 ether);
        vm.prank(stranger);
        vm.expectRevert("NOT_AUTH");
        gateway.withdrawFor(alice, 50 ether);

        vm.prank(hub);
        gateway.withdrawFor(alice, 50 ether);
        assertEq(usdt.balanceOf(alice), 1_045 ether);
        assertEq(usdt.balanceOf(hub), 0);
    }

    function test_depositAndWithdrawNeedRewardsWired() public {
        ZyqorixGateway bare = new ZyqorixGateway(address(accounts), address(funder));
        vm.startPrank(alice);
        vm.expectRevert("REWARDS_NOT_SET");
        bare.deposit(address(usdt), 50 ether);
        vm.expectRevert("REWARDS_NOT_SET");
        bare.withdraw(50 ether);
        vm.stopPrank();
    }

    /* ----------------------------- Funder ----------------------------- */
    function test_adminCanChangeFunder() public {
        _funded(100 ether, 100 ether);
        ZyqorixFunder next = _newFunder();
        usdt.mint(address(next), 500 ether);

        vm.prank(hub);
        gateway.setFunder(address(next));
        assertEq(address(gateway.funder()), address(next));
        assertEq(gateway.funderBalance(), 500 ether);

        vm.prank(alice);
        gateway.withdraw(50 ether);
        assertEq(usdt.balanceOf(address(next)), 450 ether);
        assertEq(usdt.balanceOf(address(liquidity)), 5 ether);
        assertEq(usdt.balanceOf(address(funder)), 100 ether);

        vm.prank(alice);
        gateway.deposit(address(usdt), 10 ether);
        assertEq(usdt.balanceOf(address(next)), 460 ether);
    }

    function test_paymentTokenIsTheMainnetUsdt() public view {
        assertEq(gateway.token(), USDT_ADDR);
        assertEq(funder.token(), USDT_ADDR);
    }

    function test_constructorsNeedUsdtDeployed() public {
        vm.etch(USDT_ADDR, "");
        vm.expectRevert("NOT_CONTRACT");
        new ZyqorixFunder(address(accounts));
        vm.expectRevert("NOT_CONTRACT");
        new ZyqorixGateway(address(accounts), address(funder));
    }

    function test_setFunderGates() public {
        ZyqorixFunder unlinked = new ZyqorixFunder(address(accounts));
        OtherTokenFunder wrongToken = new OtherTokenFunder();

        vm.prank(stranger);
        vm.expectRevert("NOT_AUTH");
        gateway.setFunder(address(unlinked));

        vm.expectRevert("FUNDER_NOT_LINKED");
        gateway.setFunder(address(unlinked));
        vm.expectRevert("FUNDER_TOKEN_MISMATCH");
        gateway.setFunder(address(wrongToken));
        vm.expectRevert("NOT_CONTRACT");
        gateway.setFunder(stranger);
    }

    function test_setRewardsIsOwnerOnlyAndRelinkable() public {
        vm.prank(hub);
        vm.expectRevert("NOT_OWNER");
        gateway.setRewards(address(rewards));

        vm.expectRevert("SAME_REWARDS");
        gateway.setRewards(address(rewards));

        MockRewards next = new MockRewards();
        next.setGateway(address(gateway));
        gateway.setRewards(address(next));
        assertEq(address(gateway.rewards()), address(next));
        gateway.setRewards(address(rewards)); // and back again
        assertEq(address(gateway.rewards()), address(rewards));

        ZyqorixGateway bare = new ZyqorixGateway(address(accounts), address(funder));
        vm.expectRevert("NOT_CONTRACT");
        bare.setRewards(stranger);
        vm.expectRevert();
        bare.setRewards(address(usdt)); // no gateway() or walletBalance()
        vm.expectRevert("REWARDS_NOT_LINKED"); // a rewards contract built for another gateway
        bare.setRewards(address(rewards));
        MockRewards linked = new MockRewards();
        linked.setGateway(address(bare));
        bare.setRewards(address(linked));
        assertEq(address(bare.rewards()), address(linked));
    }

    function test_funderPayIsGatewayOnly() public {
        usdt.mint(address(funder), 100 ether);
        vm.prank(hub);
        vm.expectRevert("NOT_GATEWAY");
        funder.pay(hub, 1 ether);
    }

    function test_ownerCanNeverTakeThePaymentToken() public {
        usdt.mint(address(funder), 100 ether);
        vm.expectRevert("PAYMENT_TOKEN_LOCKED");
        funder.withdrawFunds(address(usdt), owner, 1 ether);

        MockToken stray = new MockToken();
        stray.mint(address(funder), 5 ether);
        vm.prank(hub);
        vm.expectRevert("NOT_OWNER");
        funder.withdrawFunds(address(stray), hub, 1 ether);
        funder.withdrawFunds(address(stray), owner, 5 ether);
        assertEq(stray.balanceOf(owner), 5 ether);
    }

    function test_funderWiringIsOwnerOnlyAndRelinkable() public {
        vm.expectRevert("SAME_GATEWAY");
        funder.setGateway(address(gateway));

        funder.setRewards(address(rewards));
        vm.expectRevert("SAME_REWARDS");
        funder.setRewards(address(rewards));

        MockRewards next = new MockRewards();
        funder.setRewards(address(next));
        assertEq(funder.rewards(), address(next));
        vm.prank(address(rewards)); // the old rewards is refused once relinked
        vm.expectRevert("NOT_REWARDS");
        funder.drawRewardPool(0);

        ZyqorixGateway other = new ZyqorixGateway(address(accounts), address(funder));
        funder.setGateway(address(other));
        assertEq(funder.gateway(), address(other));
        vm.prank(address(gateway)); // nor can the old gateway pay
        vm.expectRevert("NOT_GATEWAY");
        funder.pay(stranger, 0);

        vm.startPrank(hub);
        vm.expectRevert("NOT_OWNER");
        funder.setRewards(address(rewards));
        vm.expectRevert("NOT_OWNER");
        funder.setGateway(address(gateway));
        vm.stopPrank();
    }

    /* ---------------------------- Zero balance ------------------------- */
    function test_sweepRestoresZeroBalance() public {
        usdt.mint(address(gateway), 7 ether);

        vm.prank(stranger);
        vm.expectRevert("NOT_AUTH");
        gateway.sweep(address(usdt));

        gateway.sweep(address(usdt));
        assertEq(usdt.balanceOf(address(gateway)), 0);
        assertEq(usdt.balanceOf(address(funder)), 7 ether);

        vm.expectRevert("NOTHING");
        gateway.sweep(address(usdt));
    }

    function test_rejectsNativeCoin() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok, ) = address(gateway).call{value: 1 ether}("");
        assertFalse(ok);
    }

    function testFuzz_gatewayNeverHoldsTokens(uint96 dep, uint8 pick) public {
        uint256 amount = bound(uint256(dep), 1, 1_000 ether);
        uint256[3] memory sizes = [uint256(20 ether), 50 ether, 100 ether];
        uint256 gross = sizes[pick % 3];
        _funded(gross, gross);

        vm.prank(alice);
        gateway.deposit(address(usdt), amount);
        assertEq(usdt.balanceOf(address(gateway)), 0);

        vm.warp(START + DAY + 1);
        vm.prank(alice);
        gateway.withdraw(gross);

        assertEq(usdt.balanceOf(address(gateway)), 0);
        assertEq(usdt.balanceOf(address(funder)), amount);
        assertEq(rewards.walletBalance(alice), amount);
    }
}
