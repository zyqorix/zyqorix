// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/*
 * ZYQORIX — Liquidity Module
 * USDT/TOKEN manager on PancakeSwap V3. Ported from COC's liquidityV2.sol. The gateway calls
 * swapUSDTToToken with the withdrawal fee and burns the TOKEN it gets back.
 *
 * addLiquidityUSDT is kept from COC for any later use. It routes incoming USDT by `liquidityMode`:
 *
 *   0) ADD_LIQUIDITY  — add it to the single full-range USDT/TOKEN V3 position (the default).
 *   1) SWAP_ONLY      — swap all of it to TOKEN and hold it here; the owner sweeps with tokenWithdraw().
 *   2) SEND_TO_WALLET — forward the USDT as-is to the admin-set `tradingWallet`.
 *
 * Changed from COC: USDT, TOKEN and the PancakeSwap addresses are constructor arguments, because the
 * ZYQORIX token is not deployed yet and local tests need mocks.
 *
 * `lockLiquidity` is a one-way switch. Once called, nobody can take liquidity or tokens out, including the
 * owner, and the mode stays ADD_LIQUIDITY for good. It can never be undone.
 *
 * Setup for the fee swap: initializePool(v3Pool), which also grows the oracle → initializeApproval, then
 * wait ~30 minutes for the TWAP. Until then swapUSDTToToken reverts and the fee goes back to the funder.
 */

/* -------------------------------------------------------------------------- */
/*                             Minimal interfaces                             */
/* -------------------------------------------------------------------------- */
/// @title IERC20
/// @author ZYQORIX
/// @notice Trimmed ERC20 surface used for USDT/TOKEN transfers, approvals and balance reads.
/// @dev Only the four methods this manager calls are declared; return-bool handling is done by the
///      contract's `_safe*` helpers (which tolerate non-standard tokens that return no data).
interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
}

/// @title IERC721Receiver
/// @author ZYQORIX
/// @notice ERC721 safe-transfer receiver hook, implemented so this contract can hold the position NFT.
/// @dev Standard EIP-721 receiver interface; the implementation returns the selector to accept the token.
interface IERC721Receiver {
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        external returns (bytes4);
}

/// @title INonfungiblePositionManager
/// @author ZYQORIX
/// @notice Trimmed PancakeSwap V3 NonfungiblePositionManager surface (mint / increase / decrease /
///         collect / burn / positions) used to manage the single USDT/TOKEN position NFT.
/// @dev Ported verbatim from the PancakeSwap/Uniswap V3 periphery; only the members this manager needs
///      are kept. Struct field layout must match the on-chain manager exactly.
interface INonfungiblePositionManager {
    struct MintParams {
        address token0; address token1; uint24 fee;
        int24 tickLower; int24 tickUpper;
        uint256 amount0Desired; uint256 amount1Desired;
        uint256 amount0Min; uint256 amount1Min;
        address recipient; uint256 deadline;
    }
    struct IncreaseLiquidityParams {
        uint256 tokenId;
        uint256 amount0Desired; uint256 amount1Desired;
        uint256 amount0Min; uint256 amount1Min;
        uint256 deadline;
    }
    struct DecreaseLiquidityParams {
        uint256 tokenId; uint128 liquidity;
        uint256 amount0Min; uint256 amount1Min;
        uint256 deadline;
    }
    struct CollectParams {
        uint256 tokenId; address recipient;
        uint128 amount0Max; uint128 amount1Max;
    }

    function mint(MintParams calldata params)
        external payable returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
    function increaseLiquidity(IncreaseLiquidityParams calldata params)
        external payable returns (uint128 liquidity, uint256 amount0, uint256 amount1);
    function decreaseLiquidity(DecreaseLiquidityParams calldata params)
        external returns (uint256 amount0, uint256 amount1);
    function collect(CollectParams calldata params) external payable returns (uint256 amount0, uint256 amount1);
    function burn(uint256 tokenId) external;
    function positions(uint256 tokenId)
        external view
        returns (
            uint96 nonce, address operator, address token0, address token1, uint24 fee,
            int24 tickLower, int24 tickUpper, uint128 liquidity,
            uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0, uint128 tokensOwed1
        );
}

/// @title IPancakeV3Pool
/// @author ZYQORIX
/// @notice Trimmed PancakeSwap V3 pool surface — token/fee/tickSpacing metadata plus the `observe`
///         oracle and observation-cardinality growth used to compute the TWAP.
/// @dev Ported verbatim from the PancakeSwap/Uniswap V3 core pool interface; only read/oracle members
///      required for pricing and setup are retained.
interface IPancakeV3Pool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function tickSpacing() external view returns (int24);
    function observe(uint32[] calldata secondsAgos)
        external view returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
    function increaseObservationCardinalityNext(uint16 observationCardinalityNext) external;
}

/// @title ISwapRouter
/// @author ZYQORIX
/// @notice Trimmed PancakeSwap V3 SwapRouter surface exposing `exactInputSingle` for USDT→TOKEN swaps.
/// @dev Ported verbatim from the PancakeSwap/Uniswap V3 periphery SwapRouter; only the single-hop
///      exact-input entry point is kept.
interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn; address tokenOut; uint24 fee; address recipient;
        uint256 deadline; uint256 amountIn; uint256 amountOutMinimum; uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

/* -------------------------------------------------------------------------- */
/*                        Math libraries (verbatim, audited)                  */
/* -------------------------------------------------------------------------- */
/// @title FullMath
/// @author ZYQORIX
/// @notice Full-precision `mulDiv` — computes `a * b / denominator` with the 512-bit intermediate
///         product, so no phantom overflow occurs even when `a * b` exceeds 256 bits.
/// @dev Ported verbatim from Uniswap V3's audited FullMath library; used here for Q96 price math.
library FullMath {
    /// @dev Calculates floor(a * b / denominator) with full precision. Reverts (via `require`) if the
    ///      result overflows a uint256 or `denominator` is 0.
    /// @param a First multiplicand.
    /// @param b Second multiplicand.
    /// @param denominator Divisor (must be > 0, and > the high 256 bits of the product).
    /// @return result The 256-bit result of `a * b / denominator`.
    function mulDiv(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256 result) {
        unchecked {
            uint256 prod0;
            uint256 prod1;
            assembly {
                let mm := mulmod(a, b, not(0))
                prod0 := mul(a, b)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }
            if (prod1 == 0) {
                require(denominator > 0);
                assembly { result := div(prod0, denominator) }
                return result;
            }
            require(denominator > prod1);
            uint256 remainder;
            assembly { remainder := mulmod(a, b, denominator) }
            assembly {
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }
            uint256 twos = denominator & (~denominator + 1);
            assembly { denominator := div(denominator, twos) }
            assembly { prod0 := div(prod0, twos) }
            assembly { twos := add(div(sub(0, twos), twos), 1) }
            prod0 |= prod1 * twos;
            uint256 inv = (3 * denominator) ^ 2;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            result = prod0 * inv;
            return result;
        }
    }
}

/// @title TickMath
/// @author ZYQORIX
/// @notice Converts a V3 tick into its sqrt price ratio (Q64.96), used to turn the TWAP tick into a price.
/// @dev Ported verbatim from Uniswap V3's audited TickMath library; only `getSqrtRatioAtTick` and the
///      tick bounds are retained.
library TickMath {
    /// @notice Minimum tick that may be passed to `getSqrtRatioAtTick`.
    int24 internal constant MIN_TICK = -887272;
    /// @notice Maximum tick that may be passed to `getSqrtRatioAtTick`.
    int24 internal constant MAX_TICK = 887272;

    /// @dev Computes sqrt(1.0001^tick) * 2^96 with fixed-point bit-manipulation. Reverts with 'T' if
    ///      |tick| exceeds MAX_TICK.
    /// @param tick The tick to convert (must satisfy MIN_TICK <= tick <= MAX_TICK).
    /// @return sqrtPriceX96 The sqrt ratio at `tick` as a Q64.96 fixed-point number.
    function getSqrtRatioAtTick(int24 tick) internal pure returns (uint160 sqrtPriceX96) {
        uint256 absTick = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));
        require(absTick <= uint256(int256(MAX_TICK)), 'T');

        uint256 ratio = 0x100000000000000000000000000000000;
        if (absTick & 0x1 != 0) ratio = (ratio * 0xfffcb933bd6fad37aa2d162d1a594001) >> 128;
        if (absTick & 0x2 != 0) ratio = (ratio * 0xfff97272373d413259a46990580e213a) >> 128;
        if (absTick & 0x4 != 0) ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
        if (absTick & 0x8 != 0) ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
        if (absTick & 0x10 != 0) ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644) >> 128;
        if (absTick & 0x20 != 0) ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
        if (absTick & 0x40 != 0) ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
        if (absTick & 0x80 != 0) ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
        if (absTick & 0x100 != 0) ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
        if (absTick & 0x200 != 0) ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
        if (absTick & 0x400 != 0) ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
        if (absTick & 0x800 != 0) ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
        if (absTick & 0x1000 != 0) ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
        if (absTick & 0x2000 != 0) ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
        if (absTick & 0x4000 != 0) ratio = (ratio * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
        if (absTick & 0x8000 != 0) ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6) >> 128;
        if (absTick & 0x10000 != 0) ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
        if (absTick & 0x20000 != 0) ratio = (ratio * 0x5d6af8dedb81196699c329225ee604) >> 128;
        if (absTick & 0x40000 != 0) ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98) >> 128;
        if (absTick & 0x80000 != 0) ratio = (ratio * 0x48a170391f7dc42444e8fa2) >> 128;

        if (tick > 0) ratio = type(uint256).max / ratio;

        sqrtPriceX96 = uint160((ratio >> 32) + (ratio % (1 << 32) == 0 ? 0 : 1));
    }
}

/* -------------------------------------------------------------------------- */
/*                     Ownable / Admin / ReentrancyGuard                      */
/* -------------------------------------------------------------------------- */
/// @title Ownable
/// @author ZYQORIX
/// @notice Minimal single-owner access control: sets an initial owner at deploy and allows transfer.
/// @dev Inlined to avoid external imports. The owner is the highest-privilege role (admins are a
///      superset gate added by AdminOwnable).
abstract contract Ownable {
    /// @dev Current owner address (private; exposed via `owner()`).
    address private _owner;
    /// @notice Emitted whenever ownership moves from one address to another (including the initial set).
    /// @param previousOwner The prior owner (address(0) on the initial assignment at deploy).
    /// @param newOwner The new owner.
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /// @notice Sets the initial owner and emits {OwnershipTransferred} from address(0).
    /// @dev Reverts with "OWNABLE_ZERO_OWNER" if `initialOwner` is the zero address.
    /// @param initialOwner The address to assign as the first owner.
    constructor(address initialOwner) {
        require(initialOwner != address(0), "OWNABLE_ZERO_OWNER");
        _owner = initialOwner;
        emit OwnershipTransferred(address(0), initialOwner);
    }
    /// @dev Restricts a function to the current owner; reverts with "NOT_OWNER" otherwise.
    modifier onlyOwner() { require(msg.sender == _owner, "NOT_OWNER"); _; }
    /// @notice Returns the current owner address.
    /// @return The current owner.
    function owner() public view returns (address) { return _owner; }
    /// @notice Transfers ownership to `newOwner`. Restricted to the current owner (onlyOwner).
    /// @dev Reverts with "ZERO_ADDRESS" if `newOwner` is the zero address; emits {OwnershipTransferred}.
    /// @param newOwner The address that becomes the new owner.
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "ZERO_ADDRESS");
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }
}

/// @title AdminOwnable
/// @author ZYQORIX
/// @notice Adds an owner-managed admin allowlist on top of Ownable; admins can run day-to-day setup/ops.
/// @dev The owner is implicitly authorized everywhere `onlyAdmin` is used; admins cannot manage the
///      allowlist themselves (add/remove is onlyOwner).
abstract contract AdminOwnable is Ownable {
    /// @notice Whether an address is an authorized admin.
    mapping(address => bool) public isAdmin;
    /// @notice Emitted when an address is granted admin rights.
    /// @param admin The address that was added as an admin.
    event AdminAdded(address indexed admin);
    /// @notice Emitted when an address has its admin rights revoked.
    /// @param admin The address that was removed as an admin.
    event AdminRemoved(address indexed admin);

    /// @dev Restricts a function to the owner or an allowlisted admin; reverts "NOT_AUTHORIZED_ADMIN".
    modifier onlyAdmin() { require(msg.sender == owner() || isAdmin[msg.sender], "NOT_AUTHORIZED_ADMIN"); _; }
    /// @notice Grants admin rights to `a`. Restricted to the owner (onlyOwner).
    /// @dev Reverts "ZERO_ADDRESS" if `a` is zero, or "ALREADY_ADMIN" if already an admin; emits {AdminAdded}.
    /// @param a The address to grant admin rights.
    function addAdmin(address a) external onlyOwner {
        require(a != address(0), "ZERO_ADDRESS"); require(!isAdmin[a], "ALREADY_ADMIN");
        isAdmin[a] = true; emit AdminAdded(a);
    }
    /// @notice Revokes admin rights from `a`. Restricted to the owner (onlyOwner).
    /// @dev Reverts "ZERO_ADDRESS" if `a` is zero, or "NOT_ADMIN" if not currently an admin; emits {AdminRemoved}.
    /// @param a The address to revoke admin rights from.
    function removeAdmin(address a) external onlyOwner {
        require(a != address(0), "ZERO_ADDRESS"); require(isAdmin[a], "NOT_ADMIN");
        isAdmin[a] = false; emit AdminRemoved(a);
    }
}

/// @title ReentrancyGuard
/// @author ZYQORIX
/// @notice Prevents nested (reentrant) calls into functions marked `nonReentrant`.
/// @dev Inlined minimal guard using a 1 (unlocked) / 2 (locked) status flag.
abstract contract ReentrancyGuard {
    /// @dev Reentrancy status: 1 = not entered, 2 = entered.
    uint256 private _status = 1;
    /// @dev Locks the guard for the duration of the call; reverts "REENTRANCY" on a nested entry.
    modifier nonReentrant() { require(_status == 1, "REENTRANCY"); _status = 2; _; _status = 1; }
}

/* ========================================================================== */
/*                           TOKENLiquidity                             */
/* ========================================================================== */
/// @title ZyqorixLiquidity
/// @author ZYQORIX
/// @notice Manages a single full-range USDT/TOKEN PancakeSwap V3 position for the ZYQORIX plan. It
///         pulls the plan's Liquidity allocation in USDT (`addLiquidityUSDT`) and, per the admin-set
///         `liquidityMode`, either (0) single-sidedly adds it to the position, (1) swaps it all to TOKEN and
///         holds it, or (2) forwards the USDT to the `tradingWallet`. It also exposes a direct USDT→TOKEN
///         swap (`swapUSDTToToken`). Prices come from a 10-minute pool TWAP.
/// @dev Implements the `ILiquidity` surface the plan calls: `addLiquidityUSDT(uint256,uint24,uint256)` +
///      `TOKENID()`. The V2 toggle is a stored `liquidityMode` (not a new parameter) so the plan's call is
///      unchanged. All V3 interfaces, FullMath/TickMath, and Ownable/Admin/ReentrancyGuard are inlined
///      so it compiles with zero external imports. USDT, TOKEN and the PancakeSwap addresses are
///      immutable constructor arguments. TOKENID is 0 until an admin runs the one-time setup and mints the position,
///      at which point the membership hub routes here (otherwise it credits its liquidity wallet).
///      Setup order: depositUSDT/depositToken → initializePool → initializeApproval → initializePosition.
contract ZyqorixLiquidity is AdminOwnable, ReentrancyGuard, IERC721Receiver {
    /* ------------------------- Immutables: tokens --------------------- */
    /// @notice Paired stablecoin (BSC-USD on BSC, 18 dp).
    address public immutable USDT;
    /// @notice The ZYQORIX token (18 dp) — the token paired against USDT in the managed V3 position.
    address public immutable TOKEN;

    /* --------------------- Immutables: PancakeSwap V3 ----------------- */
    /// @dev PancakeSwap V3 NonfungiblePositionManager on BSC mainnet (mints/holds the position NFT).
    INonfungiblePositionManager private immutable POSITION_MANAGER;
    /// @dev PancakeSwap V3 SwapRouter on BSC mainnet (executes USDT→TOKEN swaps).
    ISwapRouter private immutable SWAP_ROUTER;

    /* ------------------------------ Oracle ---------------------------- */
    /// @notice The TWAP window in seconds. A longer window makes the price harder to push in a thin pool.
    uint32 public constant TWAP_WINDOW = 1800;
    /// @notice Observation slots requested from the pool at `initializePool`.
    uint16 public constant OBSERVATION_SLOTS = 200;

    /* ------------------------------ Storage --------------------------- */
    /// @dev The USDT/TOKEN V3 pool used for the TWAP oracle (set by `initializePool`).
    IPancakeV3Pool private POOL;
    /// @notice The V3 position NFT id; 0 until `initializePosition` mints it (routing falls back while 0).
    uint256 public TOKENID;  // 0 until the position is minted
    /// @notice The pool's token0 (either USDT or TOKEN); cached from the pool at `initializePool`.
    address public TOKEN0;
    /// @notice The pool's token1 (the other of USDT/TOKEN); cached from the pool at `initializePool`.
    address public TOKEN1;
    /// @notice The pool's fee tier (in hundredths of a bip); cached from the pool at `initializePool`.
    uint24 public FEE;

    /* -------------------------- V2: routing mode ---------------------- */
    /// @notice Where incoming USDT from `addLiquidityUSDT` is routed.
    /// @dev ADD_LIQUIDITY (0, default) = add to the V3 position (V1 behavior); SWAP_ONLY (1) = swap all
    ///      USDT to TOKEN and hold it; SEND_TO_WALLET (2) = forward the USDT as-is to `tradingWallet`.
    enum LiquidityMode { ADD_LIQUIDITY, SWAP_ONLY, SEND_TO_WALLET }
    /// @notice The active routing mode for `addLiquidityUSDT`. Defaults to ADD_LIQUIDITY (0).
    LiquidityMode public liquidityMode;
    /// @notice Destination for the SEND_TO_WALLET mode (the trading wallet). Must be set before that mode.
    address public tradingWallet;

    /// @notice True once the exit routes are closed for good. It can never be set back to false.
    bool public liquidityLocked;

    /* ------------------------------- Events --------------------------- */
    /// @notice Emitted once, when the exit routes are closed for good.
    event LiquidityLocked();
    /// @notice Emitted when the initial position NFT is minted.
    /// @param tokenId The id of the newly minted V3 position.
    event PositionMinted(uint256 indexed tokenId);
    /// @notice Emitted when liquidity is added to the position (initial mint or an increase).
    /// @param tokenId The position NFT id liquidity was added to.
    /// @param liquidity The amount of liquidity units added by this operation.
    event LiquidityAdded(uint256 indexed tokenId, uint128 liquidity);
    /// @notice Emitted when an emergency withdrawal pulls all liquidity/fees out and burns the position.
    /// @param to The recipient of the withdrawn funds (the caller/owner).
    /// @param liquidity The amount of liquidity that was removed from the position.
    event EmergencyWithdrawExecuted(address indexed to, uint256 liquidity);
    /// @notice Emitted on every USDT→TOKEN swap executed via the router.
    /// @param caller The swap recipient (this contract for add-liquidity, or the buyer for Product).
    /// @param tokenIn The input token (USDT).
    /// @param tokenOut The output token (TOKEN).
    /// @param amountIn The USDT amount swapped in.
    /// @param amountOut The TOKEN amount received out.
    event Swapped(address indexed caller, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut);
    /// @notice Emitted when accrued LP fees are collected from the position.
    /// @param amount0 The token0 amount reported collected by the position manager.
    /// @param amount1 The token1 amount reported collected by the position manager.
    event FeesCollected(uint256 amount0, uint256 amount1);
    /// @notice Emitted when USDT or TOKEN is deposited into the manager to seed it.
    /// @param token The token deposited (USDT or TOKEN).
    /// @param from The depositor address.
    /// @param amount The amount deposited.
    event Deposited(address indexed token, address indexed from, uint256 amount);
    /// @notice Emitted when the admin changes the routing mode of `addLiquidityUSDT`.
    /// @param mode The new routing mode (0=ADD_LIQUIDITY, 1=SWAP_ONLY, 2=SEND_TO_WALLET).
    event LiquidityModeSet(LiquidityMode mode);
    /// @notice Emitted when the admin sets the SEND_TO_WALLET destination (trading wallet).
    /// @param wallet The new trading wallet address.
    event TradingWalletSet(address indexed wallet);
    /// @notice Emitted when `addLiquidityUSDT` forwards incoming USDT to the trading wallet (SEND_TO_WALLET).
    /// @param wallet The trading wallet the USDT was sent to.
    /// @param usdtAmount The USDT amount forwarded.
    event RoutedToWallet(address indexed wallet, uint256 usdtAmount);
    /// @notice Emitted when `addLiquidityUSDT` swaps incoming USDT to TOKEN and holds it (SWAP_ONLY).
    /// @param usdtIn The USDT amount swapped in.
    /// @param tokenOut The TOKEN amount received and retained by the manager.
    event SwappedOnly(uint256 usdtIn, uint256 tokenOut);

    /// @notice Deploys the manager, setting the deployer as owner.
    /// @dev Owner is `msg.sender` (via Ownable). Reverts ZERO_ADDRESS, SAME_TOKEN, or NOT_CONTRACT if any
    ///      address has no code. These addresses can never be changed.
    /// @param usdt The paired stablecoin (BSC mainnet 0x55d398326f99059fF775485246999027B3197955).
    /// @param token The ZYQORIX token.
    /// @param positionManager PancakeSwap V3 NonfungiblePositionManager (BSC mainnet 0x46A15B0b27311cedF172AB29E4f4766fbE7F4364).
    /// @param swapRouter PancakeSwap V3 SwapRouter (BSC mainnet 0x1b81D678ffb9C0263b24A97847620C99d213eB14).
    constructor(address usdt, address token, address positionManager, address swapRouter) Ownable(msg.sender) {
        require(usdt != address(0) && token != address(0), "ZERO_ADDRESS");
        require(positionManager != address(0) && swapRouter != address(0), "ZERO_ADDRESS");
        require(usdt != token, "SAME_TOKEN");
        require(usdt.code.length != 0 && token.code.length != 0, "NOT_CONTRACT");
        require(positionManager.code.length != 0 && swapRouter.code.length != 0, "NOT_CONTRACT");
        USDT = usdt;
        TOKEN = token;
        POSITION_MANAGER = INonfungiblePositionManager(positionManager);
        SWAP_ROUTER = ISwapRouter(swapRouter);
    }

    /// @dev Blocks an exit route once the liquidity is locked. Reverts LIQUIDITY_LOCKED.
    modifier notLocked() {
        require(!liquidityLocked, "LIQUIDITY_LOCKED");
        _;
    }

    /// @notice Close the exit routes for good: `emergencyWithdraw`, `tokenWithdraw`, `setLiquidityMode` and
    ///         `revokeApproval` stop working and the mode stays ADD_LIQUIDITY. This can never be undone. Adding
    ///         liquidity, the fee swap, `reinvestIdle` and `collectFees` keep working.
    /// @dev onlyOwner. Reverts LIQUIDITY_LOCKED if already locked, NO_POSITION if no position is minted,
    ///      EMPTY_POSITION if it holds no liquidity, NO_APPROVAL if `initializeApproval` hasn't run.
    function lockLiquidity() external onlyOwner notLocked {
        require(TOKENID != 0, "NO_POSITION");
        (, , , , , , , uint128 currentLiquidity, , , , ) = POSITION_MANAGER.positions(TOKENID);
        require(currentLiquidity > 0, "EMPTY_POSITION");
        require(IERC20(USDT).allowance(address(this), address(SWAP_ROUTER)) != 0, "NO_APPROVAL");
        liquidityMode = LiquidityMode.ADD_LIQUIDITY;
        liquidityLocked = true;
        emit LiquidityModeSet(LiquidityMode.ADD_LIQUIDITY);
        emit LiquidityLocked();
    }

    /* ====================== CORE: called by the plan ====================== */

    /// @notice Pull `usdtAmount` of USDT from the caller and route it per the admin-set `liquidityMode`:
    ///         (0) ADD_LIQUIDITY — single-sided add to the V3 position (swap ~90% to TOKEN if short, then
    ///         increase); (1) SWAP_ONLY — swap it all to TOKEN and hold it here; (2) SEND_TO_WALLET — forward
    ///         the USDT as-is to `tradingWallet`. Returns a non-zero "handled" amount, or 0 on a pre-pull guard.
    /// @dev nonReentrant. Approve-then-call: the caller must pre-approve `usdtAmount` of USDT to this contract.
    ///      Pre-pull guards (zero amount, slippage > 5000 bps, plus per-mode readiness: ADD_LIQUIDITY needs a
    ///      minted position, SWAP_ONLY needs the pool set, SEND_TO_WALLET needs `tradingWallet` set) return 0
    ///      WITHOUT taking funds so the caller's fallback is correct. Once USDT is pulled every failure REVERTS
    ///      (atomic) and the function never returns 0 — so the caller's try/catch fallback can never
    ///      double-count USDT that already left.
    /// @param usdtAmount The USDT amount to pull and route.
    /// @param slippageBps Slippage tolerance in basis points (must be <= 5000, i.e. 50%). Ignored by SEND_TO_WALLET.
    /// @param deadline Unix timestamp after which the swap/increase must revert. Ignored by SEND_TO_WALLET.
    /// @return A non-zero amount signalling the USDT was handled (liquidity added / TOKEN out / USDT forwarded),
    ///         or 0 if a pre-pull guard short-circuited the call (nothing was pulled).
    function addLiquidityUSDT(uint256 usdtAmount, uint24 slippageBps, uint256 deadline)
        external nonReentrant returns (uint256)
    {
        if (usdtAmount == 0 || slippageBps > 5000) return 0;
        LiquidityMode mode = liquidityMode;

        // Per-mode pre-pull readiness guards: return 0 (nothing taken) so the caller falls back cleanly.
        if (mode == LiquidityMode.ADD_LIQUIDITY) {
            if (TOKENID == 0) return 0;
        } else if (mode == LiquidityMode.SWAP_ONLY) {
            if (address(POOL) == address(0)) return 0;
        } else {
            // SEND_TO_WALLET
            if (tradingWallet == address(0)) return 0;
        }

        _safeTransferFrom(USDT, msg.sender, address(this), usdtAmount);

        // From here the USDT has been pulled — every path must return non-zero or REVERT (atomic), never
        // return 0, so the caller's try/catch fallback never double-counts USDT that already left.

        // Option 3: forward the USDT as-is to the trading wallet (no swap).
        if (mode == LiquidityMode.SEND_TO_WALLET) {
            _safeTransfer(USDT, tradingWallet, usdtAmount);
            emit RoutedToWallet(tradingWallet, usdtAmount);
            return usdtAmount;
        }

        // Option 2: swap the whole amount to TOKEN and keep it here (owner sweeps via tokenWithdraw).
        if (mode == LiquidityMode.SWAP_ONLY) {
            uint256 tokenOut = _swapUSDT(usdtAmount, slippageBps, address(this), deadline);
            emit SwappedOnly(usdtAmount, tokenOut);
            return tokenOut; // >= 1 (guaranteed non-zero by _swapUSDT)
        }

        // Option 1 (default): single-sided add to the V3 position.
        uint256 usdtForLiq = usdtAmount;
        uint256 tokenForLiq = convertToken(USDT, usdtAmount);

        if (tokenForLiq > IERC20(TOKEN).balanceOf(address(this))) {
            uint256 usdtToSwap = (usdtAmount * 90) / 100;
            _swapUSDTToToken(usdtToSwap, slippageBps, deadline);
            usdtForLiq = usdtAmount - usdtToSwap;
            tokenForLiq = convertToken(USDT, usdtForLiq);
        }

        require(
            usdtForLiq != 0 && tokenForLiq != 0
            && usdtForLiq <= IERC20(USDT).balanceOf(address(this))
            && tokenForLiq <= IERC20(TOKEN).balanceOf(address(this)),
            "ADD_LIQ_NOOP"
        );

        return _increaseLiquidity(usdtForLiq, tokenForLiq, slippageBps, deadline);
    }

    /// @notice Set the routing mode used by `addLiquidityUSDT` (the V2 toggle).
    /// @dev onlyAdmin. 0=ADD_LIQUIDITY, 1=SWAP_ONLY, 2=SEND_TO_WALLET. SEND_TO_WALLET is inert until
    ///      `tradingWallet` is set (the pre-pull guard returns 0). Emits {LiquidityModeSet}.
    /// @param mode The routing mode to activate.
    function setLiquidityMode(LiquidityMode mode) external onlyAdmin notLocked {
        liquidityMode = mode;
        emit LiquidityModeSet(mode);
    }

    /// @notice Set the trading-wallet destination used by the SEND_TO_WALLET mode.
    /// @dev onlyAdmin. Reverts "ZERO_WALLET" if `wallet` is the zero address. Emits {TradingWalletSet}.
    /// @param wallet The trading wallet to receive forwarded USDT.
    function setTradingWallet(address wallet) external onlyAdmin {
        require(wallet != address(0), "ZERO_WALLET");
        tradingWallet = wallet;
        emit TradingWalletSet(wallet);
    }

    /// @dev Split out of addLiquidityUSDT to keep the stack shallow (no via-IR needed). Maps the USDT/TOKEN
    ///      legs onto token0/token1, applies slippage to each min, calls the position manager, and emits
    ///      {LiquidityAdded}.
    /// @param usdtForLiq The USDT leg to supply.
    /// @param tokenForLiq The TOKEN leg to supply.
    /// @param slippageBps Slippage tolerance in basis points applied to both minimums.
    /// @param deadline Unix timestamp after which the increase must revert.
    /// @return The amount of liquidity units added by the position manager.
    function _increaseLiquidity(uint256 usdtForLiq, uint256 tokenForLiq, uint24 slippageBps, uint256 deadline)
        private returns (uint256)
    {
        uint256 amt0 = TOKEN0 == USDT ? usdtForLiq : tokenForLiq;
        uint256 amt1 = TOKEN1 == USDT ? usdtForLiq : tokenForLiq;
        (uint128 liquidity,,) =
            POSITION_MANAGER.increaseLiquidity(INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: TOKENID,
                amount0Desired: amt0,
                amount1Desired: amt1,
                amount0Min: _applySlippage(amt0, slippageBps),
                amount1Min: _applySlippage(amt1, slippageBps),
                deadline: deadline
            }));
        emit LiquidityAdded(TOKENID, liquidity);
        return liquidity;
    }

    /* ============================ PRICING/SWAP ============================ */

    /// @notice TWAP-priced conversion of `amountIn` of `tokenIn` (USDT or TOKEN) into the other token.
    /// @dev Reads the 30-minute TWAP (Q96 token1-per-token0) and applies it in the correct direction based
    ///      on which token is token0. Reverts "InvalidPrice" if the TWAP is 0, or "InvalidToken" if
    ///      `tokenIn` is neither USDT nor TOKEN. View-only estimate — no swap is performed.
    /// @param tokenIn The input token to price (must be USDT or TOKEN).
    /// @param amountIn The input amount to convert.
    /// @return expectedOut The TWAP-implied output amount of the other token.
    function convertToken(address tokenIn, uint256 amountIn) public view returns (uint256 expectedOut) {
        uint256 priceX96 = getTwapPriceX96(); // token1 per token0, Q96
        require(priceX96 != 0, "InvalidPrice");
        bool usdtIsToken0 = (TOKEN0 == USDT);
        if (tokenIn == USDT) {
            expectedOut = usdtIsToken0
                ? FullMath.mulDiv(amountIn, priceX96, 1 << 96)
                : FullMath.mulDiv(amountIn, 1 << 96, priceX96);
        } else if (tokenIn == TOKEN) {
            expectedOut = usdtIsToken0
                ? FullMath.mulDiv(amountIn, 1 << 96, priceX96)
                : FullMath.mulDiv(amountIn, priceX96, 1 << 96);
        } else {
            revert("InvalidToken");
        }
    }

    /// @notice 30-minute TWAP price (Q64.96). Reverts if the oracle is unavailable — never falls back to the
    ///         flash-loan-manipulable spot price.
    /// @dev Observes the pool `TWAP_WINDOW` seconds ago vs now, derives the average tick (rounding toward negative infinity
    ///      for negative deltas), clamps it to [MIN_TICK, MAX_TICK], and squares the sqrt ratio to a Q96
    ///      price. Reverts "Pool not initialized" if unset, or "TwapPriceFailed" if `observe` reverts or
    ///      yields a zero price (e.g. insufficient observation history).
    /// @return priceX96 The TWAP price as token1-per-token0 in Q64.96 fixed point.
    function getTwapPriceX96() public view returns (uint256 priceX96) {
        require(address(POOL) != address(0), "Pool not initialized");
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = TWAP_WINDOW;
        secondsAgos[1] = 0;
        uint256 twapPrice = 0;
        try POOL.observe(secondsAgos) returns (int56[] memory tickCumulatives, uint160[] memory) {
            int56 tickDelta = tickCumulatives[1] - tickCumulatives[0];
            int24 twapTick = int24(
                tickDelta < 0
                    ? (tickDelta - int56(uint56(TWAP_WINDOW - 1))) / int56(uint56(TWAP_WINDOW))
                    : tickDelta / int56(uint56(TWAP_WINDOW))
            );
            if (twapTick < TickMath.MIN_TICK) twapTick = TickMath.MIN_TICK;
            if (twapTick > TickMath.MAX_TICK) twapTick = TickMath.MAX_TICK;
            uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(twapTick);
            twapPrice = FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 1 << 96);
        } catch {
            twapPrice = 0;
        }
        require(twapPrice != 0, "TwapPriceFailed");
        priceX96 = twapPrice;
    }

    /// @notice Swap `usdtAmount` USDT → TOKEN (pulls USDT from the caller) and send the TOKEN to `recipient`.
    ///         Used by the ZYQORIX plan to deliver the Product allocation when the TOKEN reserve is short.
    ///         Reverts (atomically) if the pool/TWAP isn't ready — the caller catches and falls back.
    /// @dev nonReentrant. Approve-then-call: the caller must pre-approve `usdtAmount` of USDT. Reverts "ZERO"
    ///      if `usdtAmount` is 0, "SLIPPAGE_TOO_HIGH" if `slippageBps` > 5000, or "ZERO_RECIPIENT" if
    ///      `recipient` is the zero address.
    /// @param usdtAmount The USDT amount to pull and swap.
    /// @param slippageBps Slippage tolerance in basis points (must be <= 5000) applied to the TWAP estimate.
    /// @param recipient The address to receive the TOKEN output.
    /// @param deadline Unix timestamp after which the swap must revert.
    /// @return amountOut The TOKEN amount delivered to `recipient`.
    function swapUSDTToToken(uint256 usdtAmount, uint24 slippageBps, address recipient, uint256 deadline)
        external nonReentrant returns (uint256 amountOut)
    {
        require(usdtAmount > 0, "ZERO");
        require(slippageBps <= 5000, "SLIPPAGE_TOO_HIGH");
        require(recipient != address(0), "ZERO_RECIPIENT");
        _safeTransferFrom(USDT, msg.sender, address(this), usdtAmount);
        amountOut = _swapUSDT(usdtAmount, slippageBps, recipient, deadline);
    }

    /// @dev Internal USDT→TOKEN swap to `recipient` (this contract for add-liquidity, or the buyer for Product).
    ///      Prices via the TWAP, floors the minimum out at 1 (never 0), routes `exactInputSingle` with no
    ///      price limit, and emits {Swapped}. Reverts "ZERO_OUT" if the TWAP estimate is 0.
    /// @param usdtAmount The USDT amount to swap in.
    /// @param slippageBps Slippage tolerance in basis points applied to the TWAP-derived minimum out.
    /// @param recipient The address to receive the TOKEN output.
    /// @param deadline Unix timestamp after which the swap must revert.
    /// @return amountOut The TOKEN amount received from the router.
    function _swapUSDT(uint256 usdtAmount, uint24 slippageBps, address recipient, uint256 deadline)
        internal returns (uint256 amountOut)
    {
        uint256 expectedOut = convertToken(USDT, usdtAmount);
        require(expectedOut > 0, "ZERO_OUT");
        uint256 minOut = _applySlippage(expectedOut, slippageBps);
        if (minOut == 0) minOut = 1;
        amountOut = SWAP_ROUTER.exactInputSingle(ISwapRouter.ExactInputSingleParams({
            tokenIn: USDT,
            tokenOut: TOKEN,
            fee: FEE,
            recipient: recipient,
            deadline: deadline,
            amountIn: usdtAmount,
            amountOutMinimum: minOut,
            sqrtPriceLimitX96: 0
        }));
        emit Swapped(recipient, USDT, TOKEN, usdtAmount, amountOut);
    }

    /// @dev Convenience wrapper: swap USDT→TOKEN with this contract as recipient (used by add-liquidity).
    /// @param usdtAmount The USDT amount to swap in.
    /// @param slippageBps Slippage tolerance in basis points.
    /// @param deadline Unix timestamp after which the swap must revert.
    /// @return The TOKEN amount received into this contract.
    function _swapUSDTToToken(uint256 usdtAmount, uint24 slippageBps, uint256 deadline)
        internal returns (uint256)
    {
        return _swapUSDT(usdtAmount, slippageBps, address(this), deadline);
    }

    /* ============================== SETUP ================================ */

    /// @notice Deposit USDT to seed the manager before the initial position is minted.
    /// @dev nonReentrant. Pulls via `transferFrom` (caller must pre-approve). Reverts "ZERO" if `amount`
    ///      is 0; emits {Deposited}.
    /// @param amount The USDT amount to deposit.
    function depositUSDT(uint256 amount) external nonReentrant {
        require(amount > 0, "ZERO");
        _safeTransferFrom(USDT, msg.sender, address(this), amount);
        emit Deposited(USDT, msg.sender, amount);
    }

    /// @notice Deposit TOKEN to seed the manager before the initial position is minted.
    /// @dev nonReentrant. Pulls via `transferFrom` (caller must pre-approve). Reverts "ZERO" if `amount`
    ///      is 0; emits {Deposited}.
    /// @param amount The TOKEN amount to deposit.
    function depositToken(uint256 amount) external nonReentrant {
        require(amount > 0, "ZERO");
        _safeTransferFrom(TOKEN, msg.sender, address(this), amount);
        emit Deposited(TOKEN, msg.sender, amount);
    }

    /// @notice Grant the position manager and swap router unlimited USDT/TOKEN allowance. Call once at setup.
    /// @dev onlyAdmin, nonReentrant. Approves max USDT and TOKEN to both POSITION_MANAGER and SWAP_ROUTER.
    function initializeApproval() external onlyAdmin nonReentrant {
        _safeApprove(USDT, address(POSITION_MANAGER), type(uint256).max);
        _safeApprove(TOKEN, address(POSITION_MANAGER), type(uint256).max);
        _safeApprove(USDT, address(SWAP_ROUTER), type(uint256).max);
        _safeApprove(TOKEN, address(SWAP_ROUTER), type(uint256).max);
    }

    /// @notice Revoke the position manager and swap router USDT/TOKEN allowances (emergency).
    /// @dev onlyAdmin, nonReentrant, closed by `lockLiquidity`. Sets USDT and TOKEN allowance to 0 for both
    ///      POSITION_MANAGER and SWAP_ROUTER if either is suspected compromised.
    function revokeApproval() external onlyAdmin notLocked nonReentrant {
        _safeApprove(USDT, address(POSITION_MANAGER), 0);
        _safeApprove(TOKEN, address(POSITION_MANAGER), 0);
        _safeApprove(USDT, address(SWAP_ROUTER), 0);
        _safeApprove(TOKEN, address(SWAP_ROUTER), 0);
    }

    /// @notice Bind the manager to a USDT/TOKEN PancakeSwap V3 pool and cache its fee and token ordering.
    /// @dev onlyAdmin, nonReentrant. Reads and stores FEE/TOKEN0/TOKEN1, and requests `OBSERVATION_SLOTS` so
    ///      the TWAP has enough history. Reverts "ZERO_POOL" if
    ///      `poolAddress` is zero, "NOT_A_POOL" if it is a wallet or a contract without a pool's `fee()`,
    ///      or "POOL_NOT_USDT_TOKEN" if the pool's pair is not exactly USDT/TOKEN.
    /// @param poolAddress The PancakeSwap V3 pool address to bind.
    function initializePool(address poolAddress) external onlyAdmin nonReentrant {
        require(address(POOL) == address(0), "Pool already initialized");
        require(poolAddress != address(0), "ZERO_POOL");
        require(poolAddress.code.length != 0, "NOT_A_POOL");
        POOL = IPancakeV3Pool(poolAddress);
        try POOL.fee() returns (uint24 poolFee) {
            FEE = poolFee;
        } catch {
            revert("NOT_A_POOL");
        }
        TOKEN0 = POOL.token0();
        TOKEN1 = POOL.token1();
        require(
            (TOKEN0 == USDT && TOKEN1 == TOKEN) || (TOKEN0 == TOKEN && TOKEN1 == USDT),
            "POOL_NOT_USDT_TOKEN"
        );
        POOL.increaseObservationCardinalityNext(OBSERVATION_SLOTS);
    }

    /// @notice Grow the pool's observation cardinality beyond `OBSERVATION_SLOTS` if a busy pool needs more.
    ///         NOTE: the TWAP only succeeds once ~30 min of history has accumulated; until then the plan
    ///         falls back (Liquidity → liquidityBalance, Product → reserve/skip).
    /// @dev onlyAdmin. Reverts "Pool not initialized" if the pool is unset. Calls the pool's
    ///      `increaseObservationCardinalityNext`.
    /// @param next The target observation cardinality to grow the pool toward.
    function growObservationCardinality(uint16 next) external onlyAdmin {
        require(address(POOL) != address(0), "Pool not initialized");
        POOL.increaseObservationCardinalityNext(next);
    }

    /// @notice Mint the initial full-range USDT/TOKEN position from the seeded balances, setting TOKENID.
    /// @dev onlyAdmin, nonReentrant. Uses the full seeded USDT/TOKEN balances as the desired amounts,
    ///      snaps the min/max tick to the pool's tickSpacing for full range, and mints to this contract.
    ///      Reverts "Pool not initialized" (unset pool), "Position already exists" (TOKENID != 0), or
    ///      "NO_FUNDS" (either seeded balance is 0). Emits {PositionMinted} and {LiquidityAdded}.
    function initializePosition() external onlyAdmin nonReentrant {
        require(address(POOL) != address(0), "Pool not initialized");
        require(TOKENID == 0, "Position already exists");
        uint256 tokenBal = IERC20(TOKEN).balanceOf(address(this));
        uint256 usdtBal = IERC20(USDT).balanceOf(address(this));
        require(tokenBal > 0 && usdtBal > 0, "NO_FUNDS");
        int24 tickSpacing = POOL.tickSpacing();
        (uint256 newTokenId, uint128 liquidity,,) =
            POSITION_MANAGER.mint(INonfungiblePositionManager.MintParams({
                token0: TOKEN0, token1: TOKEN1, fee: FEE,
                tickLower: (TickMath.MIN_TICK / tickSpacing) * tickSpacing,
                tickUpper: (TickMath.MAX_TICK / tickSpacing) * tickSpacing,
                amount0Desired: TOKEN0 == USDT ? usdtBal : tokenBal,
                amount1Desired: TOKEN1 == USDT ? usdtBal : tokenBal,
                amount0Min: 0, amount1Min: 0,
                recipient: address(this), deadline: block.timestamp + 300
            }));
        TOKENID = newTokenId;
        emit PositionMinted(newTokenId);
        emit LiquidityAdded(newTokenId, liquidity);
    }

    /* =============================== OPS ================================= */

    /// @notice Collect accrued LP fees to the owner.
    /// @dev onlyAdmin, nonReentrant. Collects max fees into this contract, then forwards only the measured
    ///      USDT/TOKEN gains to the owner (leaving any pre-existing seed untouched). Reverts "No position"
    ///      if TOKENID is 0. Emits {FeesCollected}.
    /// @return amount0 The token0 amount reported collected by the position manager.
    /// @return amount1 The token1 amount reported collected by the position manager.
    function collectFees() external onlyAdmin nonReentrant returns (uint256 amount0, uint256 amount1) {
        require(TOKENID != 0, "No position");
        uint256 usdtBefore = IERC20(USDT).balanceOf(address(this));
        uint256 tokenBefore = IERC20(TOKEN).balanceOf(address(this));
        (amount0, amount1) = POSITION_MANAGER.collect(INonfungiblePositionManager.CollectParams({
            tokenId: TOKENID, recipient: address(this),
            amount0Max: type(uint128).max, amount1Max: type(uint128).max
        }));
        uint256 usdtGain = IERC20(USDT).balanceOf(address(this)) - usdtBefore;
        uint256 tokenGain = IERC20(TOKEN).balanceOf(address(this)) - tokenBefore;
        if (usdtGain > 0) _safeTransfer(USDT, owner(), usdtGain);
        if (tokenGain > 0) _safeTransfer(TOKEN, owner(), tokenGain);
        emit FeesCollected(amount0, amount1);
    }

    /// @notice Add USDT and TOKEN sitting idle here to the position, in the TWAP ratio. This is how leftovers
    ///         reach the position once `lockLiquidity` has closed `tokenWithdraw`.
    /// @dev onlyAdmin, nonReentrant. The larger side is trimmed to match the smaller one and the rest stays
    ///      idle. If only USDT is idle, top up with `depositToken` first. Reverts "No position",
    ///      "SLIPPAGE_TOO_HIGH" or "NOTHING_IDLE".
    /// @param slippageBps Slippage tolerance in basis points (must be <= 5000).
    /// @return The amount of liquidity units added.
    function reinvestIdle(uint24 slippageBps) external onlyAdmin nonReentrant returns (uint256) {
        require(TOKENID != 0, "No position");
        require(slippageBps <= 5000, "SLIPPAGE_TOO_HIGH");
        uint256 usdtAmount = IERC20(USDT).balanceOf(address(this));
        uint256 tokenAmount = IERC20(TOKEN).balanceOf(address(this));
        require(usdtAmount != 0 && tokenAmount != 0, "NOTHING_IDLE");
        uint256 tokenNeeded = convertToken(USDT, usdtAmount);
        if (tokenNeeded <= tokenAmount) tokenAmount = tokenNeeded;
        else usdtAmount = convertToken(TOKEN, tokenAmount);
        return _increaseLiquidity(usdtAmount, tokenAmount, slippageBps, block.timestamp + 300);
    }

    /// @notice Emergency: pull all liquidity + fees to the owner and burn the position.
    /// @dev onlyOwner, nonReentrant. Decreases all liquidity, collects everything to the caller, best-effort
    ///      burns the NFT (try/catch), resets TOKENID to 0, and sweeps any idle USDT/TOKEN to the caller.
    ///      Reverts "No position minted" (TOKENID 0) or "Zero liquidity" (position empty). Emits
    ///      {EmergencyWithdrawExecuted}.
    function emergencyWithdraw() external onlyOwner notLocked nonReentrant {
        require(TOKENID != 0, "No position minted");
        (, , , , , , , uint128 currentLiquidity, , , , ) = POSITION_MANAGER.positions(TOKENID);
        require(currentLiquidity > 0, "Zero liquidity");
        POSITION_MANAGER.decreaseLiquidity(INonfungiblePositionManager.DecreaseLiquidityParams({
            tokenId: TOKENID, liquidity: currentLiquidity, amount0Min: 0, amount1Min: 0,
            deadline: block.timestamp + 300
        }));
        POSITION_MANAGER.collect(INonfungiblePositionManager.CollectParams({
            tokenId: TOKENID, recipient: msg.sender,
            amount0Max: type(uint128).max, amount1Max: type(uint128).max
        }));
        try POSITION_MANAGER.burn(TOKENID) {} catch {}
        TOKENID = 0;
        uint256 tokenLeft = IERC20(TOKEN).balanceOf(address(this));
        uint256 usdtLeft = IERC20(USDT).balanceOf(address(this));
        if (tokenLeft > 0) _safeTransfer(TOKEN, msg.sender, tokenLeft);
        if (usdtLeft > 0) _safeTransfer(USDT, msg.sender, usdtLeft);
        emit EmergencyWithdrawExecuted(msg.sender, currentLiquidity);
    }

    /// @notice Recover idle (non-position) USDT/TOKEN held by this contract to the owner.
    /// @dev onlyOwner, nonReentrant. Sweeps the contract's current USDT and TOKEN balances to the owner;
    ///      does not touch the active position. No-op if both balances are 0.
    function tokenWithdraw() external onlyOwner notLocked nonReentrant {
        uint256 tokenLeft = IERC20(TOKEN).balanceOf(address(this));
        uint256 usdtLeft = IERC20(USDT).balanceOf(address(this));
        if (tokenLeft > 0) _safeTransfer(TOKEN, owner(), tokenLeft);
        if (usdtLeft > 0) _safeTransfer(USDT, owner(), usdtLeft);
    }

    /// @notice ERC721 receiver hook — accepts incoming position NFTs (e.g. the minted V3 position).
    /// @dev Pure; returns the ERC721 receiver magic value to signal acceptance. All params are ignored.
    /// @return The `onERC721Received` selector, confirming the transfer is accepted.
    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    /* ============================= HELPERS ============================== */

    /// @dev Computes a slippage-adjusted minimum: `amount * (10000 - slippageBps) / 10000`, floored at 1
    ///      for any non-zero amount so a min-out is never 0. Returns 0 only when `amount` is 0.
    /// @param amount The reference amount to discount.
    /// @param slippageBps Slippage tolerance in basis points (of 10000).
    /// @return The minimum acceptable amount after slippage.
    function _applySlippage(uint256 amount, uint24 slippageBps) private pure returns (uint256) {
        if (amount == 0) return 0;
        uint256 min = (amount * (10000 - slippageBps)) / 10000;
        return min == 0 ? 1 : min;
    }

    /// @dev Safe ERC20 transfer tolerating non-standard (no-return) tokens. Reverts "NOT_CONTRACT" if the
    ///      token has no code, or "TRANSFER_FAILED" if the call fails or returns false.
    /// @param token The ERC20 token to transfer.
    /// @param to The recipient.
    /// @param amount The amount to transfer.
    function _safeTransfer(address token, address to, uint256 amount) private {
        require(token.code.length > 0, "NOT_CONTRACT");
        (bool ok, bytes memory data) = token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "TRANSFER_FAILED");
    }

    /// @dev Safe ERC20 transferFrom tolerating non-standard (no-return) tokens. Reverts "NOT_CONTRACT" if
    ///      the token has no code, or "TRANSFER_FROM_FAILED" if the call fails or returns false.
    /// @param token The ERC20 token to pull.
    /// @param from The address funds are pulled from (must have approved this contract).
    /// @param to The recipient.
    /// @param amount The amount to transfer.
    function _safeTransferFrom(address token, address from, address to, uint256 amount) private {
        require(token.code.length > 0, "NOT_CONTRACT");
        (bool ok, bytes memory data) =
            token.call(abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, amount));
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "TRANSFER_FROM_FAILED");
    }

    /// @dev Safe ERC20 approve tolerating non-standard (no-return) tokens. Reverts "NOT_CONTRACT" if the
    ///      token has no code, or "APPROVE_FAILED" if the call fails or returns false.
    /// @param token The ERC20 token to approve.
    /// @param spender The spender being granted the allowance.
    /// @param amount The allowance to set.
    function _safeApprove(address token, address spender, uint256 amount) private {
        require(token.code.length > 0, "NOT_CONTRACT");
        (bool ok, bytes memory data) =
            token.call(abi.encodeWithSelector(IERC20.approve.selector, spender, amount));
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "APPROVE_FAILED");
    }
}