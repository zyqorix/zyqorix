// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/*
 * ZYQORIX — Rewards Module
 * The member ledger and compensation plan. It keeps the wallet balance (deposits, referral rewards and
 * claimed daily rewards), agent balances, tiers and capping. It moves no tokens: the gateway and funder do.
 *
 * The daily reward is a fixed 1% of tier value, backed in advance: an activation is rejected unless the
 * funder's reward pool already holds its full 3x capping, which is then reserved for that member. The pool
 * can only receive money through funder.fundRewards after trading capital is repaid, so deposits can never
 * reach it and the contract never owes a daily reward it does not already hold.
 */

/* -------------------------------------------------------------------------- */
/*                              Wiring interfaces                             */
/* -------------------------------------------------------------------------- */
/// @title IZyqorixAccounts
/// @notice Membership, genealogy and authority. This contract must be an accounts admin for vesting.
interface IZyqorixAccounts {
    function isUser(address account) external view returns (bool);
    function checkIsAdmin(address account) external view returns (bool);
    function registeredAt(address account) external view returns (uint256);
    function getAffiliate(address user) external view returns (address referral, uint256 directCount);
}

/// @title IZyqorixGateway
/// @notice The current funder, liquidity and token settings.
interface IZyqorixGateway {
    function funder() external view returns (address);
    function liquidity() external view returns (address);
    function token() external view returns (address);
    function liquiditySlippageBps() external view returns (uint24);
    function paused() external view returns (bool);
}

/// @title IZyqorixFunder
/// @notice The activation flows and the reward pool ledger.
interface IZyqorixFunder {
    function sendToTrading(uint256 amount) external;
    function sendToLiquidity(address liquidity, uint256 amount, uint24 slippageBps) external;
    function drawRewardPool(uint256 amount) external;
}

/// @title IZyqorixLiquidity
/// @notice The TWAP price used to size the vesting position.
interface IZyqorixLiquidity {
    function convertToken(address tokenIn, uint256 amountIn) external view returns (uint256);
}

/// @title IZyqorixVesting
/// @notice Reserves the ZQR bought by an activation.
interface IZyqorixVesting {
    function createPosition(address user, uint256 amount) external returns (uint256 index);
    function available() external view returns (uint256);
}

/// @title ReentrancyGuard
/// @author ZYQORIX
/// @notice Prevents nested (re-entrant) calls to functions marked `nonReentrant`.
abstract contract ReentrancyGuard {
    uint256 private _status = 1; // 1 = not entered, 2 = entered

    modifier nonReentrant() {
        require(_status == 1, "REENTRANCY");
        _status = 2;
        _;
        _status = 1;
    }
}

/* ========================================================================== */
/*                               ZyqorixRewards                               */
/* ========================================================================== */
/// @title ZyqorixRewards
/// @author ZYQORIX
/// @notice Activation, capping, referral, agent and daily rewards.
/// @dev Must be an accounts admin (for `vesting.createPosition`), and set once on the gateway and funder.
contract ZyqorixRewards is ReentrancyGuard {
    /* ------------------------------ Constants -------------------------- */
    /// @notice Basis-points denominator (10000 = 100%).
    uint256 public constant BPS = 10_000;
    /// @notice The fixed daily reward: 1% of active tier value.
    uint256 public constant DAILY_BPS = 100;
    /// @notice Capping added by an activation: 300% of the tier.
    uint256 public constant CAP_BPS = 30_000;
    /// @notice Number of tiers.
    uint256 public constant TIER_COUNT = 6;
    /// @notice Sponsor levels paid the generation bonus on a daily claim.
    uint256 public constant GENERATION_LEVELS = 10;
    /// @notice Generation bonus per level: 10% of the claimed daily reward.
    uint256 public constant GENERATION_BPS = 1_000;
    /// @notice Active direct referrals needed for the higher referral rate.
    uint256 public constant REFERRAL_ACTIVE_DIRECTS = 5;

    /* ------------------------------- Wiring ---------------------------- */
    /// @notice The accounts contract. Immutable.
    IZyqorixAccounts public immutable accounts;
    /// @notice The gateway. Immutable.
    IZyqorixGateway public immutable gateway;
    /// @notice Seconds in a reward day. 1 days everywhere except the local test chain, where it is 1 minutes
    ///         and a leadership month is 30 of them.
    uint256 public immutable DAY;
    /// @notice The vesting contract. Changed with `setVesting` when a new vesting model replaces it.
    IZyqorixVesting public vesting;

    /* ---------------------------- Distribution ------------------------- */
    /// @notice Share of an activation sent to liquidity.
    uint256 public liquidityBps = 5_000;
    /// @notice Share of an activation sent to the trading wallet.
    uint256 public tradingBps = 1_000;
    /// @notice Referral rate with fewer than REFERRAL_ACTIVE_DIRECTS active directs.
    uint256 public referralLowBps = 500;
    /// @notice Referral rate with REFERRAL_ACTIVE_DIRECTS or more active directs.
    uint256 public referralHighBps = 1_000;
    /// @notice Share of an activation paid to the first active agent up the tree.
    uint256 public agentBps = 500;
    /// @notice Share of an activation recorded for the leadership pool.
    uint256 public leadershipBps = 500;
    /// @notice How many levels the agent walk checks.
    uint256 public agentWalkLimit = 50;

    /* ------------------------------ Balances --------------------------- */
    /// @notice Spendable and withdrawable balance: deposits, referral, claimed daily and leadership rewards.
    mapping(address => uint256) public walletBalance;
    /// @notice Agent rewards, withdrawn through the gateway with the cooldown and no fee.
    mapping(address => uint256) public agentBalance;
    /// @notice Whether an admin has nominated this member as an agent.
    mapping(address => bool) public isAgent;
    /// @notice Lifetime earnings per member: daily, referral, generation, agent and leadership.
    mapping(address => uint256) public totalIncome;
    /// @notice Lifetime earnings across all members.
    uint256 public totalRewardsDistributed;
    /// @notice USDT owed to the leadership program across all months. Held in the funder.
    uint256 public leadershipPool;

    /* -------------------------- Leadership pool ------------------------ */
    /// @notice Members paid from each month's pool.
    uint256 public constant LEADER_COUNT = 10;
    /// @notice How many sponsors each month's ranking lists for the UI. Only the first LEADER_COUNT share.
    uint256 public constant LEADER_LIST = 50;
    /// @notice Leadership pool per calendar month (year * 12 + month - 1, UTC).
    mapping(uint256 => uint256) public monthPool;
    /// @notice Direct referral activation volume per month, per sponsor.
    mapping(uint256 => mapping(address => uint256)) public monthVolume;
    /// @dev Each month's top sponsors, highest volume first.
    mapping(uint256 => address[]) private _leaders;
    /// @dev The months each sponsor had volume in, oldest first.
    mapping(address => uint256[]) private _leaderMonths;
    /// @dev How far through `_leaderMonths` each sponsor has claimed.
    mapping(address => uint256) private _leaderClaimed;
    /// @dev The latest month that received pool money. A month with no qualifier rolls forward from here.
    uint256 private _poolMonth;

    /* ------------------------------ Capping ---------------------------- */
    /// @dev Capping left per member, per tier. Above zero means the tier is active.
    mapping(address => mapping(uint256 => uint256)) private _tierCapping;
    /// @dev A member's active tiers, oldest first. At most TIER_COUNT entries.
    mapping(address => uint8[]) private _activeTiers;
    /// @notice The only tier each member can activate next. Tiers run in order and each opens once, except
    ///         the last, which can be activated again whenever its capping is zero.
    mapping(address => uint256) public nextTier;
    /// @notice Bitmask of the tiers each member has fully capped at least once.
    mapping(address => uint256) public cappedTiers;
    /// @notice Total capping left per member. Zero means inactive.
    mapping(address => uint256) public capping;
    /// @notice Sum of a member's active tier prices.
    mapping(address => uint256) public activeValue;
    /// @notice Direct referrals with capping above zero.
    mapping(address => uint256) public activeDirects;

    /* --------------------------- Daily rewards ------------------------- */
    /// @notice Sum of every member's active tier value.
    uint256 public totalActiveValue;
    /// @notice Sum of every member's capping. This is the money reserved in the reward pool.
    uint256 public totalCapping;
    /// @notice Reward pool money not reserved for anyone. New activations reserve from this.
    uint256 public unreservedPool;
    /// @notice Start of the first whole day not yet settled for a member.
    mapping(address => uint256) public lastAccrual;
    /// @notice Generation bonus earned and not yet claimed. Already deducted from capping.
    mapping(address => uint256) public generationBalance;
    /// @notice Sum of every generation balance.
    uint256 public totalGeneration;
    /// @notice Daily rewards settled for a member and not yet claimed.
    mapping(address => uint256) public unclaimedDaily;
    /// @notice When a member last claimed.
    mapping(address => uint256) public lastClaim;

    /* ------------------------------- Events ---------------------------- */
    /// @notice Emitted when `user` activates a tier.
    /// @param user The member.
    /// @param tier The tier index.
    /// @param price The USDT price.
    /// @param zqr The ZQR placed in vesting.
    event Activated(address indexed user, uint256 indexed tier, uint256 price, uint256 zqr);
    /// @notice Emitted when vesting can't cover an activation, so no position is created.
    /// @param user The member.
    /// @param tier The tier activated.
    /// @param zqr The ZQR the tier was worth.
    event VestingSkipped(address indexed user, uint256 indexed tier, uint256 zqr);
    /// @notice Emitted when the vesting contract is replaced.
    /// @param vesting The new vesting contract.
    event VestingSet(address indexed vesting);
    /// @notice Emitted when a tier's capping reaches zero.
    /// @param user The member.
    /// @param tier The tier index.
    event TierDeactivated(address indexed user, uint256 indexed tier);
    /// @notice Emitted when a sponsor earns a referral reward.
    /// @param sponsor The sponsor.
    /// @param from The activating member.
    /// @param amount The amount paid after capping.
    event ReferralPaid(address indexed sponsor, address indexed from, uint256 amount);
    /// @notice Emitted when an agent earns an agent reward.
    /// @param agent The agent.
    /// @param from The activating member.
    /// @param amount The amount recorded.
    event AgentPaid(address indexed agent, address indexed from, uint256 amount);
    /// @notice Emitted when a member claims daily rewards.
    /// @param user The member.
    /// @param amount The amount moved to the wallet balance.
    event DailyClaimed(address indexed user, uint256 amount);
    /// @notice Emitted when a sponsor earns a generation bonus.
    /// @param sponsor The sponsor.
    /// @param from The member who claimed.
    /// @param level The sponsor level, 1 to 10.
    /// @param amount The amount earned after capping.
    event GenerationPaid(address indexed sponsor, address indexed from, uint256 level, uint256 amount);
    /// @notice Emitted when a member claims their generation bonus.
    /// @param user The member.
    /// @param amount The amount moved to the wallet balance.
    event GenerationClaimed(address indexed user, uint256 amount);
    /// @notice Emitted when a member claims leadership rewards.
    /// @param user The member.
    /// @param amount The amount moved to their wallet balance.
    event LeadershipClaimed(address indexed user, uint256 amount);
    /// @notice Emitted when money enters the unreserved pool.
    /// @param amount The amount.
    event ProfitReceived(uint256 amount);
    /// @notice Emitted when an admin nominates or removes an agent.
    /// @param user The member.
    /// @param active True if nominated.
    event AgentSet(address indexed user, bool active);
    /// @notice Emitted when an admin corrects a sponsor's active direct count.
    /// @param sponsor The sponsor.
    /// @param count The corrected count.
    event ActiveDirectsSynced(address indexed sponsor, uint256 count);
    /// @notice Emitted when the distribution changes.
    event DistributionSet(uint256 liquidityBps, uint256 tradingBps, uint256 referralLowBps, uint256 referralHighBps, uint256 agentBps, uint256 leadershipBps);
    /// @notice Emitted when the agent walk limit changes.
    /// @param limit The new limit.
    event AgentWalkLimitSet(uint256 limit);

    /* ------------------------------ Modifiers -------------------------- */
    /// @dev Restricts a function to the accounts owner or an explicit admin. Reverts NOT_AUTH.
    modifier onlyAuth() {
        require(accounts.checkIsAdmin(msg.sender), "NOT_AUTH");
        _;
    }

    /// @dev Restricts a function to the gateway. Reverts NOT_GATEWAY.
    modifier onlyGateway() {
        require(msg.sender == address(gateway), "NOT_GATEWAY");
        _;
    }

    /* ----------------------------- Constructor ------------------------- */
    /// @notice Deploy the rewards contract.
    /// @param accountsAddr The accounts contract.
    /// @param gatewayAddr The gateway.
    /// @param vestingAddr The vesting contract.
    /// @param dayLength Seconds in a reward day: 1 days, or 1 minutes on chain 31337 only.
    /// @dev Reverts ZERO_ADDRESS / NOT_CONTRACT / BAD_DAY.
    constructor(address accountsAddr, address gatewayAddr, address vestingAddr, uint256 dayLength) {
        require(accountsAddr != address(0) && gatewayAddr != address(0) && vestingAddr != address(0), "ZERO_ADDRESS");
        require(accountsAddr.code.length > 0 && gatewayAddr.code.length > 0 && vestingAddr.code.length > 0, "NOT_CONTRACT");
        require(dayLength == 1 days || (dayLength == 1 minutes && block.chainid == 31337), "BAD_DAY");
        DAY = dayLength;
        accounts = IZyqorixAccounts(accountsAddr);
        gateway = IZyqorixGateway(gatewayAddr);
        vesting = IZyqorixVesting(vestingAddr);
    }

    /* ============================= ACTIVATE ============================ */
    /// @notice Activate the next tier from your wallet balance. Tiers run in order from $50, none can be
    ///         skipped, and each opens once, except the last, which reopens whenever its capping is zero. You
    ///         receive 3x capping and, while vesting holds enough unreserved ZQR, the tier's worth of ZQR in
    ///         vesting. The price is distributed.
    /// @param tier 0..5 for $50, $100, $200, $400, $800, $1600.
    /// @dev Reverts PAUSED / NOT_REGISTERED / BAD_TIER / TIER_USED / TIER_SKIPPED / TIER_ACTIVE / TIER_LOCKED /
    ///      INSUFFICIENT_WALLET / INSUFFICIENT_REWARD_POOL / NO_LIQUIDITY / NO_PRICE. The ZQR price must be
    ///      readable: the liquidity contract reverts when its pool or TWAP isn't ready. With TOKENID 0 the funder
    ///      keeps the liquidity share. When vesting is short the activation still goes through with no
    ///      position, zqr 0 in {Activated}, and {VestingSkipped}. There are no partial positions.
    function activate(uint256 tier) external nonReentrant {
        address user = msg.sender;
        require(!gateway.paused(), "PAUSED");
        require(accounts.isUser(user), "NOT_REGISTERED");
        require(tier < TIER_COUNT, "BAD_TIER");

        _sync(user);

        if (tier == TIER_COUNT - 1 && nextTier[user] == TIER_COUNT) {
            require(_tierCapping[user][tier] == 0, "TIER_ACTIVE");
        } else {
            require(tier >= nextTier[user], "TIER_USED");
            require(tier == nextTier[user], "TIER_SKIPPED");
        }
        require(isTierUnlocked(user, tier), "TIER_LOCKED");
        uint256 price = tierPrice(tier);
        require(walletBalance[user] >= price, "INSUFFICIENT_WALLET");
        uint256 reserve = (price * CAP_BPS) / BPS;
        require(reserve <= unreservedPool, "INSUFFICIENT_REWARD_POOL");
        address lp = gateway.liquidity();
        require(lp != address(0), "NO_LIQUIDITY");
        uint256 zqr = IZyqorixLiquidity(lp).convertToken(gateway.token(), price);
        require(zqr != 0, "NO_PRICE");

        walletBalance[user] -= price;
        unreservedPool -= reserve;
        nextTier[user] = tier + 1;
        _addTier(user, tier, price);

        if (zqr <= vesting.available()) {
            vesting.createPosition(user, zqr);
        } else {
            emit VestingSkipped(user, tier, zqr);
            zqr = 0;
        }

        _addLeadership((price * leadershipBps) / BPS);
        _payReferral(user, price);
        _payAgent(user, price);

        IZyqorixFunder funder = IZyqorixFunder(gateway.funder());
        funder.sendToTrading((price * tradingBps) / BPS);
        funder.sendToLiquidity(lp, (price * liquidityBps) / BPS, gateway.liquiditySlippageBps());
        emit Activated(user, tier, price, zqr);
    }

    /* ============================== DAILY ============================== */
    /// @notice Claim your fixed daily rewards into your wallet balance. Once per reward day.
    /// @return amount The amount claimed.
    /// @dev Reverts CLAIM_COOLDOWN / NOTHING_TO_CLAIM.
    function claimDaily() external nonReentrant returns (uint256 amount) {
        address user = msg.sender;
        require(block.timestamp >= lastClaim[user] + DAY, "CLAIM_COOLDOWN");
        _sync(user);
        amount = unclaimedDaily[user];
        require(amount > 0, "NOTHING_TO_CLAIM");
        unclaimedDaily[user] = 0;
        lastClaim[user] = block.timestamp;
        walletBalance[user] += amount;
        IZyqorixFunder(gateway.funder()).drawRewardPool(amount);
        emit DailyClaimed(user, amount);
        _payGeneration(user, amount);
    }

    /// @notice Claim your generation bonus into your wallet balance. It already used your capping when earned.
    /// @return amount The amount claimed.
    /// @dev Reverts NOTHING_TO_CLAIM.
    function claimGeneration() external nonReentrant returns (uint256 amount) {
        address user = msg.sender;
        amount = generationBalance[user];
        require(amount > 0, "NOTHING_TO_CLAIM");
        generationBalance[user] = 0;
        totalGeneration -= amount;
        walletBalance[user] += amount;
        IZyqorixFunder(gateway.funder()).drawRewardPool(amount);
        emit GenerationClaimed(user, amount);
    }

    /* ============================ LEADERSHIP =========================== */
    /// @notice Claim your leadership rewards for every finished month, including any you missed. A month
    ///         closes at 00:00 UTC on the 1st. They go to your wallet balance and use no capping.
    /// @return total The amount claimed.
    /// @dev Reverts NOTHING_TO_CLAIM.
    function claimLeadership() external nonReentrant returns (uint256 total) {
        address user = msg.sender;
        uint256 current = _monthKey(block.timestamp);
        uint256[] storage months = _leaderMonths[user];
        uint256 i = _leaderClaimed[user];
        while (i < months.length && months[i] < current) {
            total += _leaderShare(months[i], user);
            i++;
        }
        _leaderClaimed[user] = i;
        require(total > 0, "NOTHING_TO_CLAIM");

        leadershipPool -= total;
        walletBalance[user] += total;
        _recordIncome(user, total);
        emit LeadershipClaimed(user, total);
    }

    /* ============================ TRADING ============================== */
    /// @notice Add money to the unreserved pool. Called by the funder.
    /// @param amount The amount.
    /// @dev Reverts NOT_FUNDER.
    function notifyProfit(uint256 amount) external {
        require(msg.sender == gateway.funder(), "NOT_FUNDER");
        unreservedPool += amount;
        emit ProfitReceived(amount);
    }

    /* ============================== GATEWAY ============================ */
    /// @notice Record a deposit in `user`'s wallet balance.
    function creditDeposit(address user, uint256 amount) external onlyGateway {
        walletBalance[user] += amount;
    }

    /// @notice Debit a withdrawal from `user`'s wallet balance.
    function debitWallet(address user, uint256 amount) external onlyGateway {
        walletBalance[user] -= amount;
    }

    /// @notice Debit an agent withdrawal from `user`'s agent balance.
    function debitAgent(address user, uint256 amount) external onlyGateway {
        agentBalance[user] -= amount;
    }

    /* ============================== ADMIN ============================== */
    /// @notice Nominate or remove an agent.
    /// @param user The member.
    /// @param active True to nominate.
    /// @dev onlyAuth. Reverts NOT_REGISTERED.
    function setAgent(address user, bool active) external onlyAuth {
        require(accounts.isUser(user), "NOT_REGISTERED");
        isAgent[user] = active;
        emit AgentSet(user, active);
    }

    /// @notice Correct a sponsor's active direct count after an admin changes the genealogy.
    /// @param sponsor The sponsor.
    /// @param count The correct count.
    /// @dev onlyAuth.
    function syncActiveDirects(address sponsor, uint256 count) external onlyAuth {
        activeDirects[sponsor] = count;
        emit ActiveDirectsSynced(sponsor, count);
    }

    /// @notice Set the activation distribution. Whatever is left of the highest total stays in the funder as
    ///         the withdrawal buffer.
    /// @dev onlyAuth. Reverts BAD_DISTRIBUTION.
    function setDistribution(
        uint256 liquidity_, uint256 trading_, uint256 referralLow_, uint256 referralHigh_, uint256 agent_, uint256 leadership_
    ) external onlyAuth {
        require(referralLow_ <= referralHigh_, "BAD_DISTRIBUTION");
        require(liquidity_ + trading_ + referralHigh_ + agent_ + leadership_ <= BPS, "BAD_DISTRIBUTION");
        liquidityBps = liquidity_;
        tradingBps = trading_;
        referralLowBps = referralLow_;
        referralHighBps = referralHigh_;
        agentBps = agent_;
        leadershipBps = leadership_;
        emit DistributionSet(liquidity_, trading_, referralLow_, referralHigh_, agent_, leadership_);
    }

    /// @notice Set how many levels the agent walk checks.
    /// @param limit The new limit (1 to 500).
    /// @dev onlyAuth. Reverts BAD_LIMIT.
    function setAgentWalkLimit(uint256 limit) external onlyAuth {
        require(limit > 0 && limit <= 500, "BAD_LIMIT");
        agentWalkLimit = limit;
        emit AgentWalkLimitSet(limit);
    }

    /// @notice Point activations at a new vesting contract. Existing records stay on the old one.
    /// @param vestingAddr The new vesting contract.
    /// @dev onlyAuth. Reverts NOT_CONTRACT.
    function setVesting(address vestingAddr) external onlyAuth {
        require(vestingAddr.code.length > 0, "NOT_CONTRACT");
        vesting = IZyqorixVesting(vestingAddr);
        emit VestingSet(vestingAddr);
    }

    /* ============================== VIEWS ============================== */
    /// @notice The USDT price of tier `tier`: 50, 100, 200, 400, 800, 1600.
    /// @param tier The tier index.
    /// @return The price (18-dp).
    function tierPrice(uint256 tier) public pure returns (uint256) {
        return (50 ether) << tier;
    }

    /// @notice Capping left on one of `user`'s tiers.
    /// @param user The member.
    /// @param tier The tier index.
    /// @return The capping left. Zero means inactive.
    function tierCapping(address user, uint256 tier) external view returns (uint256) {
        return _tierCapping[user][tier];
    }

    /// @notice Whether `user` still has capping once their unsettled days are counted.
    /// @param user The member.
    /// @return True if active.
    function isActive(address user) external view returns (bool) {
        return capping[user] > _accrued(user);
    }

    /// @notice `user`'s active tiers, oldest first.
    /// @param user The member.
    /// @return The tier indexes.
    function activeTiers(address user) external view returns (uint8[] memory) {
        return _activeTiers[user];
    }

    /// @notice Whether `user` can activate `tier`: the first pair is open from registration; later pairs open
    ///         on the day counter or when the previous pair has both capped, whichever comes first.
    /// @param user The member.
    /// @param tier The tier index.
    /// @return True if unlocked.
    function isTierUnlocked(address user, uint256 tier) public view returns (bool) {
        uint256 pair = tier / 2;
        if (pair == 0) return true;
        if (block.timestamp >= accounts.registeredAt(user) + pair * 60 * DAY) return true;
        uint256 previous = 3 << ((pair - 1) * 2);
        return cappedTiers[user] & previous == previous;
    }

    /// @notice One-call dashboard snapshot for a member.
    struct UserView {
        uint256 walletBalance;
        uint256 agentBalance;
        uint256 capping;
        uint256 activeValue;
        uint256 activeDirects;
        uint256 totalIncome;
        uint256 pendingDaily;
        uint256 pendingLeadership;
        uint256 generationBalance;
        uint256 monthVolume;
        uint256 nextClaim;
        uint8[] activeTiers;
        bool isAgent;
    }

    /// @notice Everything a dashboard needs for `user`.
    /// @param user The member.
    /// @return v The snapshot.
    function getUser(address user) external view returns (UserView memory v) {
        v.walletBalance = walletBalance[user];
        v.agentBalance = agentBalance[user];
        v.capping = capping[user];
        v.activeValue = activeValue[user];
        v.activeDirects = activeDirects[user];
        v.totalIncome = totalIncome[user];
        v.pendingDaily = pendingDaily(user);
        v.pendingLeadership = pendingLeadership(user);
        v.generationBalance = generationBalance[user];
        v.monthVolume = monthVolume[_monthKey(block.timestamp)][user];
        v.nextClaim = lastClaim[user] == 0 ? 0 : lastClaim[user] + DAY;
        v.activeTiers = _activeTiers[user];
        v.isAgent = isAgent[user];
    }

    /// @notice The top sponsors for a month, highest volume first.
    /// @param month The month key.
    /// @return The sponsors, at most LEADER_LIST. Only the first LEADER_COUNT share the pool.
    function monthLeaders(uint256 month) external view returns (address[] memory) {
        return _leaders[month];
    }

    /// @notice The calendar-month key for now (year * 12 + month - 1, UTC). With a test-chain DAY, the number of
    ///         30-DAY periods since 1970.
    /// @return The month key.
    function currentMonth() external view returns (uint256) {
        return _monthKey(block.timestamp);
    }

    /// @notice Leadership rewards `user` can claim now.
    /// @param user The member.
    /// @return total The claimable amount.
    function pendingLeadership(address user) public view returns (uint256 total) {
        uint256 current = _monthKey(block.timestamp);
        uint256[] storage months = _leaderMonths[user];
        for (uint256 i = _leaderClaimed[user]; i < months.length && months[i] < current; i++) {
            total += _leaderShare(months[i], user);
        }
    }

    /// @notice Daily rewards `user` can claim now.
    /// @param user The member.
    /// @return amount The claimable amount.
    function pendingDaily(address user) public view returns (uint256 amount) {
        return unclaimedDaily[user] + _accrued(user);
    }

    /* ---------------------------- Internals ---------------------------- */
    /// @dev Whole days since the last settlement at 1% of active value, stepping through tiers oldest first
    ///      because the daily amount falls as each one caps out. Never more than the member's capping.
    function _accrued(address user) internal view returns (uint256 total) {
        uint256 value = activeValue[user];
        if (value == 0) return 0;
        uint256 daysLeft = (block.timestamp - lastAccrual[user]) / DAY;
        uint8[] storage list = _activeTiers[user];
        uint256 carry; // overshoot past a tier in its final day, taken from the next tier
        for (uint256 i = 0; i < list.length && daysLeft > 0; i++) {
            uint256 tier = list[i];
            uint256 left = _tierCapping[user][tier];
            if (carry >= left) {
                carry -= left;
                value -= tierPrice(tier);
                continue;
            }
            left -= carry;
            carry = 0;
            uint256 rate = (value * DAILY_BPS) / BPS;
            uint256 needed = (left + rate - 1) / rate; // days for this tier to cap, rounded up
            uint256 taken = needed < daysLeft ? needed : daysLeft;
            uint256 earned = rate * taken;
            total += earned;
            daysLeft -= taken;
            if (earned < left) break;
            carry = earned - left;
            value -= tierPrice(tier);
        }
        uint256 limit = capping[user];
        if (total > limit) total = limit;
    }

    /// @dev Settle `user`'s whole days against their capping. The reserved money stays in the funder's reward
    ///      pool until they claim.
    function _sync(address user) internal {
        uint256 earned = _accrued(user);
        lastAccrual[user] += ((block.timestamp - lastAccrual[user]) / DAY) * DAY;
        if (earned == 0) return;
        uint256 paid = _useCapping(user, earned);
        unclaimedDaily[user] += paid;
        _recordIncome(user, paid);
    }

    /// @dev Deduct `amount` from `user`'s capping, oldest tier first, deactivating tiers that reach zero.
    /// @return used The amount actually covered by capping.
    function _useCapping(address user, uint256 amount) internal returns (uint256 used) {
        uint8[] storage list = _activeTiers[user];
        uint256 removed;
        uint256 n = list.length;
        for (uint256 i = 0; i < n && used < amount; i++) {
            uint256 tier = list[i];
            uint256 left = _tierCapping[user][tier];
            uint256 want = amount - used;
            uint256 take = want < left ? want : left;
            _tierCapping[user][tier] = left - take;
            used += take;
            if (take == left) {
                removed++;
                uint256 price = tierPrice(tier);
                activeValue[user] -= price;
                totalActiveValue -= price;
                cappedTiers[user] |= 1 << tier;
                emit TierDeactivated(user, tier);
            }
        }
        if (removed > 0) {
            for (uint256 i = removed; i < n; i++) list[i - removed] = list[i];
            for (uint256 i = 0; i < removed; i++) list.pop();
        }
        capping[user] -= used;
        totalCapping -= used;
        if (removed > 0 && capping[user] == 0) _changeActiveDirects(user, false);
    }

    /// @dev Open a tier: add its capping and tier value, and count the member as active for their sponsor.
    function _addTier(address user, uint256 tier, uint256 price) internal {
        bool wasInactive = capping[user] == 0;
        uint256 cap = (price * CAP_BPS) / BPS;
        _tierCapping[user][tier] = cap;
        _activeTiers[user].push(uint8(tier));
        capping[user] += cap;
        totalCapping += cap;
        if (wasInactive) lastAccrual[user] = block.timestamp;
        activeValue[user] += price;
        totalActiveValue += price;
        if (wasInactive) _changeActiveDirects(user, true);
    }

    /// @dev Add to this month's pool.
    function _addLeadership(uint256 amount) internal {
        uint256 month = _monthKey(block.timestamp);
        _rollPool(month);
        monthPool[month] += amount;
        leadershipPool += amount;
    }

    /// @dev Move the last month's pool forward if nobody qualified for it.
    function _rollPool(uint256 month) internal {
        uint256 last = _poolMonth;
        if (last == month) return;
        if (_leaders[last].length == 0) {
            monthPool[month] += monthPool[last];
            monthPool[last] = 0;
        }
        _poolMonth = month;
    }

    /// @dev Add `amount` to `sponsor`'s volume this month and keep the top list sorted.
    function _addVolume(address sponsor, uint256 amount) internal {
        uint256 month = _monthKey(block.timestamp);
        uint256 volume = monthVolume[month][sponsor];
        if (volume == 0) _leaderMonths[sponsor].push(month);
        volume += amount;
        monthVolume[month][sponsor] = volume;

        address[] storage top = _leaders[month];
        uint256 n = top.length;
        uint256 at = n;
        for (uint256 i = 0; i < n; i++) {
            if (top[i] == sponsor) {
                at = i;
                break;
            }
        }
        if (at == n) {
            if (n < LEADER_LIST) {
                top.push(sponsor);
            } else {
                at = n - 1;
                if (volume <= monthVolume[month][top[at]]) return; // a tie keeps whoever got there first
                top[at] = sponsor;
            }
        }
        while (at > 0 && monthVolume[month][top[at - 1]] < volume) {
            top[at] = top[at - 1];
            top[at - 1] = sponsor;
            at--;
        }
    }

    /// @dev `user`'s share of a month's pool: pool × their volume ÷ the top ten's volume. Zero outside the top ten.
    function _leaderShare(uint256 month, address user) internal view returns (uint256) {
        address[] storage top = _leaders[month];
        uint256 n = top.length < LEADER_COUNT ? top.length : LEADER_COUNT;
        uint256 sum;
        bool listed;
        for (uint256 i = 0; i < n; i++) {
            sum += monthVolume[month][top[i]];
            if (top[i] == user) listed = true;
        }
        if (!listed) return 0;
        return (monthPool[month] * monthVolume[month][user]) / sum;
    }

    /// @dev Calendar-month key (year * 12 + month - 1) for a UTC timestamp.
    function _monthKey(uint256 ts) internal view returns (uint256) {
        if (DAY != 1 days) return ts / (30 * DAY);
        uint256 z = ts / 86400 + 719468;
        uint256 era = z / 146097;
        uint256 doe = z - era * 146097;
        uint256 yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
        uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        uint256 mp = (5 * doy + 2) / 153;
        uint256 month = mp < 10 ? mp + 3 : mp - 9;
        uint256 year = yoe + era * 400 + (month <= 2 ? 1 : 0);
        return year * 12 + month - 1;
    }

    /// @dev Add to the lifetime earnings totals.
    function _recordIncome(address user, uint256 amount) internal {
        totalIncome[user] += amount;
        totalRewardsDistributed += amount;
    }

    /// @dev Keep the sponsor's active direct count in step with `user` going active or inactive.
    function _changeActiveDirects(address user, bool up) internal {
        (address sponsor, ) = accounts.getAffiliate(user);
        if (sponsor == address(0)) return;
        if (up) activeDirects[sponsor] += 1;
        else if (activeDirects[sponsor] > 0) activeDirects[sponsor] -= 1;
    }

    /// @dev Count the activation towards the sponsor's monthly volume and pay them 5% or 10% into their wallet,
    ///      limited by their capping. An inactive sponsor gets neither. Whatever isn't paid stays in the funder.
    function _payReferral(address user, uint256 price) internal {
        (address sponsor, ) = accounts.getAffiliate(user);
        if (sponsor == address(0)) return;
        _sync(sponsor);
        if (capping[sponsor] == 0) return;
        _addVolume(sponsor, price);
        uint256 rate = activeDirects[sponsor] >= REFERRAL_ACTIVE_DIRECTS ? referralHighBps : referralLowBps;
        uint256 paid = _useCapping(sponsor, (price * rate) / BPS);
        walletBalance[sponsor] += paid;
        unreservedPool += paid; // capping used by referral income frees that reserve for new activations
        _recordIncome(sponsor, paid);
        emit ReferralPaid(sponsor, user, paid);
    }

    /// @dev Walk up 10 sponsor levels from `user` and pay each one 10% of the claimed daily reward, limited by
    ///      their capping. A sponsor with zero capping is skipped, but still counts as a level. The bonus comes
    ///      out of the sponsor's own capping, so it is already covered by their reserve.
    function _payGeneration(address user, uint256 amount) internal {
        uint256 bonus = (amount * GENERATION_BPS) / BPS;
        if (bonus == 0) return;
        (address cursor, ) = accounts.getAffiliate(user);
        for (uint256 level = 1; level <= GENERATION_LEVELS && cursor != address(0); level++) {
            _sync(cursor);
            if (capping[cursor] > 0) {
                uint256 paid = _useCapping(cursor, bonus);
                generationBalance[cursor] += paid;
                totalGeneration += paid;
                _recordIncome(cursor, paid);
                emit GenerationPaid(cursor, user, level, paid);
            }
            (cursor, ) = accounts.getAffiliate(cursor);
        }
    }

    /// @dev Walk up the tree from `user`, including `user`, and pay the first active agent. It uses no capping.
    ///      Inactive agents are skipped. If none is found within the limit, the share stays in the funder.
    function _payAgent(address user, uint256 price) internal {
        address cursor = user;
        for (uint256 i = 0; i < agentWalkLimit && cursor != address(0); i++) {
            if (isAgent[cursor] && capping[cursor] > 0) {
                uint256 amount = (price * agentBps) / BPS;
                agentBalance[cursor] += amount;
                _recordIncome(cursor, amount);
                emit AgentPaid(cursor, user, amount);
                return;
            }
            (cursor, ) = accounts.getAffiliate(cursor);
        }
    }
}
