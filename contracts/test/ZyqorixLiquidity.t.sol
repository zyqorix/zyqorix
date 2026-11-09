// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {ZyqorixAccounts} from "../accounts.sol";
import {ZyqorixFunder} from "../funder.sol";
import {ZyqorixGateway} from "../gateway.sol";
import {ZyqorixLiquidity} from "../liquidity.sol";

contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function mint(address to, uint256 v) public { balanceOf[to] += v; totalSupply += v; }
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

contract BurnableERC20 is MockERC20 {
    function burn(uint256 v) external { balanceOf[msg.sender] -= v; totalSupply -= v; }
}

/// @dev 1:1 pool with a flat TWAP (tick 0), so expected out = amount in.
contract MockPool {
    address public token0;
    address public token1;
    uint24 public constant fee = 2500;
    int24 public constant tickSpacing = 50;
    bool public observeFails;
    uint16 public cardinalityNext;
    int56 public tick;

    constructor(address a, address b) { (token0, token1) = a < b ? (a, b) : (b, a); }
    function setObserveFails(bool v) external { observeFails = v; }
    function setTick(int56 v) external { tick = v; }
    function increaseObservationCardinalityNext(uint16 next) external { cardinalityNext = next; }

    function observe(uint32[] calldata secondsAgos) external view returns (int56[] memory t, uint160[] memory s) {
        require(!observeFails, "OLD");
        require(secondsAgos[0] == 1800, "WRONG_WINDOW");
        t = new int56[](2);
        s = new uint160[](2);
        t[1] = tick * 1800;
    }
}

contract MockRouter {
    struct Params {
        address tokenIn; address tokenOut; uint24 fee; address recipient;
        uint256 deadline; uint256 amountIn; uint256 amountOutMinimum; uint160 sqrtPriceLimitX96;
    }
    uint256 public rateBps = 10_000;

    function setRate(uint256 bps) external { rateBps = bps; }

    function exactInputSingle(Params calldata p) external returns (uint256 out) {
        out = (p.amountIn * rateBps) / 10_000;
        require(out >= p.amountOutMinimum, "TOO_LITTLE_RECEIVED");
        MockERC20(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn);
        MockERC20(p.tokenOut).mint(p.recipient, out);
    }
}

/// @dev Records liquidity additions.
contract MockPositionManager {
    struct IncreaseParams {
        uint256 tokenId;
        uint256 amount0Desired; uint256 amount1Desired;
        uint256 amount0Min; uint256 amount1Min;
        uint256 deadline;
    }
    uint128 public liquidity = 100;
    uint256 public lastAmount0;
    uint256 public lastAmount1;

    function setLiquidity(uint128 v) external { liquidity = v; }

    function increaseLiquidity(IncreaseParams calldata p) external returns (uint128, uint256, uint256) {
        lastAmount0 = p.amount0Desired;
        lastAmount1 = p.amount1Desired;
        return (100, p.amount0Desired, p.amount1Desired);
    }

    function positions(uint256) external view returns (
        uint96, address, address, address, uint24, int24, int24, uint128, uint256, uint256, uint128, uint128
    ) {
        return (0, address(0), address(0), address(0), 0, 0, 0, liquidity, 0, 0, 0, 0);
    }

    fallback(bytes calldata) external payable returns (bytes memory) {
        return abi.encode(uint256(7), uint128(100), uint256(0), uint256(0));
    }
    receive() external payable {}
}

contract MockRewards {
    mapping(address => uint256) public walletBalance;
    address public gateway;
    function setGateway(address g) external { gateway = g; }
    function setBalance(address u, uint256 v) external { walletBalance[u] = v; }
    function creditDeposit(address, uint256) external {}
    function debitWallet(address u, uint256 v) external { walletBalance[u] -= v; }
}

contract ZyqorixLiquidityTest is Test {
    /// @dev USDT's BSC mainnet address, hardcoded in funder, gateway, liquidity and the exchanger.
    address constant USDT_ADDR = 0x55d398326f99059fF775485246999027B3197955;
    /// @dev ZQR's mainnet address, hardcoded in liquidity.sol. The mock is etched there.
    address constant ZQR = 0x43ADE7aE5E14e6dadD0f6967a0aDEADe56095e70;

    MockERC20 usdt;
    BurnableERC20 token;
    MockPool pool;
    MockRouter router;
    MockPositionManager pm;
    ZyqorixLiquidity lp;
    address funder = makeAddr("funder");
    address wallet = makeAddr("wallet");
    address recipient = makeAddr("recipient");
    address stranger = makeAddr("stranger");

    function setUp() public {
        // USDT's mainnet address is hardcoded in the contracts: etch the mock there.
        vm.etch(USDT_ADDR, type(MockERC20).runtimeCode);
        usdt = MockERC20(USDT_ADDR);
        vm.etch(ZQR, type(BurnableERC20).runtimeCode);
        token = BurnableERC20(ZQR);
        pool = new MockPool(address(usdt), address(token));
        router = new MockRouter();
        pm = new MockPositionManager();
        lp = _deploy();
        usdt.mint(funder, 1_000 ether);
        vm.prank(funder);
        usdt.approve(address(lp), type(uint256).max);
    }

    function _deploy() internal returns (ZyqorixLiquidity l) {
        l = new ZyqorixLiquidity(address(pm), address(router));
        l.initializePool(address(pool));
        l.initializeApproval();
    }

    function _route(uint256 amount, uint24 slippage) internal returns (uint256) {
        vm.prank(funder);
        return lp.addLiquidityUSDT(amount, slippage, block.timestamp);
    }

    function _swap(uint256 amount, uint24 slippage) internal returns (uint256) {
        vm.prank(funder);
        return lp.swapUSDTToToken(amount, slippage, recipient, block.timestamp);
    }

    function test_swapSendsTokenToRecipient() public {
        assertEq(_swap(10 ether, 300), 10 ether);
        assertEq(usdt.balanceOf(funder), 990 ether);
        assertEq(usdt.balanceOf(address(lp)), 0);
        assertEq(token.balanceOf(recipient), 10 ether);
    }

    function test_badPriceRevertsAndKeepsUsdtWithCaller() public {
        router.setRate(9_000); // 10% worse than TWAP, tolerance 3%
        vm.prank(funder);
        vm.expectRevert("TOO_LITTLE_RECEIVED");
        lp.swapUSDTToToken(10 ether, 300, recipient, block.timestamp);
        assertEq(usdt.balanceOf(funder), 1_000 ether);
    }

    function test_twapFailureRevertsAndKeepsUsdtWithCaller() public {
        pool.setObserveFails(true);
        vm.prank(funder);
        vm.expectRevert("TwapPriceFailed");
        lp.swapUSDTToToken(10 ether, 300, recipient, block.timestamp);
        assertEq(usdt.balanceOf(funder), 1_000 ether);
    }

    function test_swapGuards() public {
        vm.startPrank(funder);
        vm.expectRevert(bytes("ZERO"));
        lp.swapUSDTToToken(0, 300, recipient, block.timestamp);
        vm.expectRevert("SLIPPAGE_TOO_HIGH");
        lp.swapUSDTToToken(1 ether, 5_001, recipient, block.timestamp);
        vm.expectRevert("ZERO_RECIPIENT");
        lp.swapUSDTToToken(1 ether, 300, address(0), block.timestamp);
        vm.stopPrank();
    }

    function test_addLiquidityNotReadyReturnsZero() public {
        assertEq(_route(0, 300), 0);
        assertEq(_route(10 ether, 5_001), 0);
        assertEq(_route(10 ether, 300), 0); // default mode, no position yet
        lp.setLiquidityMode(ZyqorixLiquidity.LiquidityMode.SEND_TO_WALLET);
        assertEq(_route(10 ether, 300), 0); // no trading wallet yet
        assertEq(usdt.balanceOf(funder), 1_000 ether);
    }

    function test_swapOnlyModeHoldsToken() public {
        lp.setLiquidityMode(ZyqorixLiquidity.LiquidityMode.SWAP_ONLY);
        assertEq(_route(10 ether, 300), 10 ether);
        assertEq(token.balanceOf(address(lp)), 10 ether);

        lp.tokenWithdraw();
        assertEq(token.balanceOf(address(this)), 10 ether);
    }

    function test_sendToWalletForwardsUsdt() public {
        lp.setTradingWallet(wallet);
        lp.setLiquidityMode(ZyqorixLiquidity.LiquidityMode.SEND_TO_WALLET);
        assertEq(_route(10 ether, 300), 10 ether);
        assertEq(usdt.balanceOf(wallet), 10 ether);
    }

    function test_adminGates() public {
        vm.startPrank(stranger);
        vm.expectRevert("NOT_AUTHORIZED_ADMIN");
        lp.setLiquidityMode(ZyqorixLiquidity.LiquidityMode.ADD_LIQUIDITY);
        vm.expectRevert("NOT_AUTHORIZED_ADMIN");
        lp.setTradingWallet(wallet);
        vm.expectRevert("NOT_OWNER");
        lp.tokenWithdraw();
        vm.stopPrank();

        MockPool wrong = new MockPool(address(usdt), makeAddr("other"));
        ZyqorixLiquidity bare = new ZyqorixLiquidity(address(pm), address(router));
        vm.expectRevert("POOL_NOT_USDT_TOKEN");
        bare.initializePool(address(wrong));
    }

    function _lockReady() internal returns (ZyqorixLiquidity l) {
        l = new ZyqorixLiquidity(address(pm), address(router));
        l.initializePool(address(pool));
        l.initializeApproval();
        token.mint(address(this), 100 ether);
        usdt.mint(address(this), 100 ether);
        token.approve(address(l), type(uint256).max);
        usdt.approve(address(l), type(uint256).max);
        l.depositUSDT(100 ether);
        l.depositToken(100 ether);
        l.initializePosition();
    }

    function test_lockNeedsAMintedPosition() public {
        vm.expectRevert("NO_POSITION");
        lp.lockLiquidity();
    }

    function test_lockIsOwnerOnly() public {
        ZyqorixLiquidity l = _lockReady();
        l.addAdmin(wallet);
        vm.prank(wallet); // an admin is not enough
        vm.expectRevert("NOT_OWNER");
        l.lockLiquidity();
    }

    function test_lockForcesAddLiquidityMode() public {
        ZyqorixLiquidity l = _lockReady();
        l.setLiquidityMode(ZyqorixLiquidity.LiquidityMode.SEND_TO_WALLET);
        l.lockLiquidity();
        assertEq(uint8(l.liquidityMode()), uint8(ZyqorixLiquidity.LiquidityMode.ADD_LIQUIDITY));
        assertTrue(l.liquidityLocked());
    }

    function test_lockClosesEveryExitAndCannotBeUndone() public {
        ZyqorixLiquidity l = _lockReady();
        l.lockLiquidity();

        vm.expectRevert("LIQUIDITY_LOCKED");
        l.lockLiquidity();
        vm.expectRevert("LIQUIDITY_LOCKED");
        l.emergencyWithdraw();
        vm.expectRevert("LIQUIDITY_LOCKED");
        l.tokenWithdraw();
        vm.expectRevert("LIQUIDITY_LOCKED");
        l.revokeApproval();
        vm.expectRevert("LIQUIDITY_LOCKED");
        l.setLiquidityMode(ZyqorixLiquidity.LiquidityMode.SEND_TO_WALLET);
        vm.expectRevert("LIQUIDITY_LOCKED");
        l.setLiquidityMode(ZyqorixLiquidity.LiquidityMode.SWAP_ONLY);
        assertTrue(l.liquidityLocked());
    }

    function test_lockDoesNotStopAddingLiquidityOrSwapping() public {
        ZyqorixLiquidity l = _lockReady();
        l.lockLiquidity();
        usdt.mint(address(this), 20 ether);

        assertGt(l.addLiquidityUSDT(10 ether, 300, block.timestamp), 0);
        assertEq(l.swapUSDTToToken(10 ether, 300, recipient, block.timestamp), 10 ether);
        assertEq(token.balanceOf(recipient), 10 ether);
    }

    function test_poolCanOnlyBeSetOnce() public {
        MockPool other = new MockPool(address(usdt), address(token));
        vm.expectRevert("Pool already initialized");
        lp.initializePool(address(other));
    }

    function test_poolCannotBeRepointedAfterLock() public {
        ZyqorixLiquidity l = _lockReady();
        l.lockLiquidity();
        MockPool other = new MockPool(address(usdt), address(token));
        vm.expectRevert("Pool already initialized");
        l.initializePool(address(other));
    }

    function test_failedInitializePoolLeavesItOpen() public {
        ZyqorixLiquidity bare = new ZyqorixLiquidity(address(pm), address(router));
        MockPool wrong = new MockPool(address(usdt), makeAddr("other"));
        vm.expectRevert("POOL_NOT_USDT_TOKEN");
        bare.initializePool(address(wrong));
        bare.initializePool(address(pool)); // the correct pool still binds
        assertEq(bare.FEE(), 2500);
    }

    function test_nonPoolAddressGivesAClearError() public {
        ZyqorixLiquidity bare = new ZyqorixLiquidity(address(pm), address(router));
        vm.expectRevert("NOT_A_POOL");
        bare.initializePool(stranger); // a wallet
        vm.expectRevert("NOT_A_POOL");
        bare.initializePool(address(token)); // a contract that isn't a pool
        bare.initializePool(address(pool)); // the correct pool still binds
        assertEq(bare.FEE(), 2500);
    }

    function test_constructorRejectsZeroAddress() public {
        vm.expectRevert("ZERO_ADDRESS");
        new ZyqorixLiquidity(address(0), address(router));
        vm.expectRevert("ZERO_ADDRESS");
        new ZyqorixLiquidity(address(pm), address(0));
    }

    function test_constructorRejectsBadAddresses() public {
        vm.expectRevert("NOT_CONTRACT");
        new ZyqorixLiquidity(stranger, address(router));
        vm.expectRevert("NOT_CONTRACT");
        new ZyqorixLiquidity(address(pm), stranger);
    }

    function test_tokensAreTheMainnetAddresses() public view {
        assertEq(lp.TOKEN(), ZQR);
        assertEq(lp.USDT(), USDT_ADDR);
    }

    function test_constructorNeedsUsdtDeployed() public {
        vm.etch(USDT_ADDR, "");
        vm.expectRevert("NOT_CONTRACT");
        new ZyqorixLiquidity(address(pm), address(router));
    }

    function test_constructorNeedsZqrDeployed() public {
        vm.etch(ZQR, "");
        vm.expectRevert("NOT_CONTRACT");
        new ZyqorixLiquidity(address(pm), address(router));
    }

    /// @dev The launch price: tick 69082 is about 1,000 ZQR per USDT, on either side of the pool.
    function test_launchPriceConvertsCorrectly() public {
        int56 side = pool.token0() == address(usdt) ? int56(1) : int56(-1);
        pool.setTick(side * 69082);
        assertApproxEqRel(lp.convertToken(address(usdt), 100 ether), 100_000 ether, 0.001e18);
        assertApproxEqRel(lp.convertToken(address(token), 100_000 ether), 100 ether, 0.001e18);
    }

    /// @dev Each tick is 1.0001 times the one below. A wrong TickMath constant breaks this at its own bit.
    function test_everyTickConstantIsCorrect() public {
        for (uint256 bit = 1; bit < 20; bit++) {
            int56 tick = int56(uint56(1 << bit));
            pool.setTick(tick - 1);
            uint256 below = lp.getTwapPriceX96();
            pool.setTick(tick);
            assertApproxEqRel(lp.getTwapPriceX96(), (below / 10_000) * 10_001, 1e12); // within 0.0001%
        }
    }

    function test_initializePoolRequestsObservationSlots() public view {
        assertEq(pool.cardinalityNext(), lp.OBSERVATION_SLOTS());
        assertEq(lp.TWAP_WINDOW(), 1800);
    }

    function test_lockNeedsLiquidityInThePosition() public {
        ZyqorixLiquidity l = _lockReady();
        pm.setLiquidity(0);
        vm.expectRevert("EMPTY_POSITION");
        l.lockLiquidity();
    }

    function test_lockNeedsApprovals() public {
        ZyqorixLiquidity l = _lockReady();
        l.revokeApproval();
        vm.expectRevert("NO_APPROVAL");
        l.lockLiquidity();
    }

    function test_reinvestIdleTrimsTheLargerSide() public {
        ZyqorixLiquidity l = _lockReady(); // the mock leaves 100 USDT and 100 TOKEN idle
        l.lockLiquidity();

        usdt.mint(address(this), 10 ether);
        l.depositUSDT(10 ether);
        l.reinvestIdle(300);
        assertEq(pm.lastAmount0(), 100 ether);
        assertEq(pm.lastAmount1(), 100 ether);

        token.mint(address(this), 20 ether);
        l.depositToken(20 ether);
        l.reinvestIdle(300);
        assertEq(pm.lastAmount0(), 110 ether);
        assertEq(pm.lastAmount1(), 110 ether);
    }

    function test_reinvestIdleGates() public {
        vm.expectRevert("No position");
        lp.reinvestIdle(300);

        ZyqorixLiquidity l = _lockReady();
        vm.prank(stranger);
        vm.expectRevert("NOT_AUTHORIZED_ADMIN");
        l.reinvestIdle(300);
        vm.expectRevert("SLIPPAGE_TOO_HIGH");
        l.reinvestIdle(5_001);

        l.tokenWithdraw();
        vm.expectRevert("NOTHING_IDLE");
        l.reinvestIdle(300);
    }

    /// @dev Real gateway, funder and liquidity: pay the user, swap the fee, burn what comes back.
    function test_withdrawalSwapsFeeAndBurnsThroughRealContracts() public {
        ZyqorixAccounts accounts = new ZyqorixAccounts();
        ZyqorixFunder realFunder = new ZyqorixFunder(address(accounts));
        ZyqorixGateway gateway = new ZyqorixGateway(address(accounts), address(realFunder));
        MockRewards rewards = new MockRewards();
        rewards.setGateway(address(gateway));
        realFunder.setGateway(address(gateway));
        gateway.setRewards(address(rewards));
        ZyqorixLiquidity l = _lockReady();
        gateway.setLiquidity(address(l));

        address member = makeAddr("member");
        accounts.addUser(member, address(this));
        rewards.setBalance(member, 100 ether);
        usdt.mint(address(realFunder), 500 ether);

        vm.prank(member);
        gateway.withdraw(100 ether);

        assertEq(usdt.balanceOf(member), 90 ether);
        assertEq(usdt.balanceOf(address(realFunder)), 400 ether);
        assertEq(usdt.balanceOf(address(gateway)), 0);
        assertEq(usdt.balanceOf(address(router)), 10 ether); // the swapped fee
        assertEq(usdt.allowance(address(gateway), address(l)), 0);
        assertEq(token.balanceOf(address(gateway)), 0);
        assertEq(token.totalSupply(), 100 ether); // the seed: bought 10, burned 10
    }
}
