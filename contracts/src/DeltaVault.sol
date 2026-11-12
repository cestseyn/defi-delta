// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IERC7540} from "./interfaces/IERC7540.sol";
import {NavOracle} from "./NavOracle.sol";
import {DeriveAccountModule} from "./DeriveAccountModule.sol";

/// @title DeltaVault
/// @notice ERC-7540 vault on L1 whose strategy runs in a Derive v3 account (spec 01). Requests are queued into rounds
///         and priced at the NAV measured after the round's cutoff. Phase 1 runs one round per weekly option expiry.
contract DeltaVault is
    Initializable,
    ERC20Upgradeable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    IERC7540
{
    using SafeERC20 for IERC20;
    using Math for uint256;

    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE"); // the timelock
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE"); // owner multisig: setup and resume
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    uint256 internal constant WAD = 1e18;
    uint256 internal constant YEAR = 365 days;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 internal constant CHECKPOINTS = 25;

    // Hard limits (spec 05 §2).
    uint256 public constant MAX_MGMT_FEE = 0.03e18;
    uint256 public constant MAX_PERF_FEE = 0.25e18;
    uint256 public constant MAX_SWING = 0.01e18;
    uint256 public constant MAX_BUFFER = 0.3e18;
    uint256 public constant UPGRADE_FREEZE = 180 days;

    enum State {
        ACTIVE,
        REDUCE_ONLY,
        PAUSED
    }

    struct Round {
        uint64 cutoff; // 0 while the round is open and its cutoff isn't set yet
        uint64 processedAt;
        uint64 navReportId;
        bool depositsRefunded; // deposits weren't processed (vault not ACTIVE) and are returned instead
        uint256 navPre;
        uint256 pps;
        uint256 depositPrice;
        uint256 redeemPrice;
        uint256 pendingAssets;
        uint256 pendingShares;
        uint256 sharesMinted;
        uint256 assetsOwed;
        uint256 feeShares;
    }

    struct Slot {
        uint32 round;
        uint256 amount;
    }

    struct Claimable {
        uint256 depositAssets;
        uint256 shares;
        uint256 redeemShares;
        uint256 assets;
        uint256 refund;
    }

    struct Schedule {
        uint64 period; // phase 1: 7 days; phase 2: 4 hours; testnet: 1 day
        uint64 offset; // first cutoff (Unix seconds mod period); Friday 08:00 UTC = 1 day + 8 hours
        bool requireFlatOptions; // phase 1: the pricing report must show no open options
    }

    struct FeeParams {
        uint64 mgmtFee; // WAD per year
        uint64 perfFee; // WAD of gains over HWM
        uint64 crystallizeMaxInterval;
    }

    struct SwingParams {
        uint64 inNormal;
        uint64 outNormal;
        uint64 inLarge;
        uint64 outLarge;
        uint64 largeFlow; // WAD of NAV
    }

    struct BufferParams {
        uint64 min;
        uint64 target;
        uint64 max;
    }

    struct BreakerParams {
        uint64 drawdownThreshold; // WAD
        uint64 window;
        uint64 checkpointInterval;
    }

    struct Checkpoint {
        uint64 timestamp;
        uint192 pps;
    }

    IERC20 internal _asset;
    uint256 internal _scale; // 10^(36 − assetDecimals)
    NavOracle public oracle;
    DeriveAccountModule public module;
    address public feeCollector;
    State public state;
    bool public seeded;
    uint64 public upgradeFreezeUntil;

    Schedule public schedule;
    FeeParams public fees;
    SwingParams public swing;
    BufferParams public bufferParams;
    BreakerParams public breakerParams;
    uint256 public minDeposit;
    uint256 public minRedeem; // shares
    uint256 public tvlCap;
    uint128 public deriveMaxFeeUsdE18;

    uint256 public hwm;
    uint64 public lastCrystallizedAt;
    uint64 public pausedSince;
    uint64 public pausedAccum;

    // Asset buckets, tracked internally (spec 01 §6). Never derived from balanceOf.
    uint256 public idlePending;
    uint256 public reserveFunded;
    uint256 public reserveUnfunded;
    uint256 public buffer;
    uint256 public refundReserve;
    uint256 public cumulativeReceived; // assets received back from Derive

    mapping(uint32 => Round) internal _rounds;
    uint32 public lastProcessed;
    uint32 public openRound;
    uint256 public lastPps;
    uint256 public lastNavPost;

    mapping(address => Slot[2]) internal _depositSlots;
    mapping(address => Slot[2]) internal _redeemSlots;
    mapping(address => Claimable) internal _claimable;
    mapping(address => mapping(address => bool)) public isOperator;

    Checkpoint[CHECKPOINTS] internal _checkpoints;
    uint8 internal _checkpointIndex;

    event RoundClosed(uint32 indexed round, uint64 cutoff);
    event RoundProcessed(
        uint32 indexed round,
        uint64 navReportId,
        uint256 navPre,
        uint256 pps,
        uint256 depositPrice,
        uint256 redeemPrice,
        uint256 sharesMinted,
        uint256 assetsOwed,
        uint256 feeShares,
        bool depositsRefunded
    );
    event FeesCrystallized(uint256 mgmtFee, uint256 perfFee, uint256 feeShares, uint256 hwm);
    event DepositRequestCanceled(
        address indexed controller, uint256 indexed requestId, address receiver, uint256 assets
    );
    event RedeemRequestCanceled(
        address indexed controller, uint256 indexed requestId, address receiver, uint256 shares
    );
    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(
        address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares
    );
    event RefundClaimed(address indexed controller, address receiver, uint256 assets);
    event SentToDerive(uint256 amount, uint64 depositNonce);
    event DeriveWithdrawalRequested(uint256 amount, uint64 withdrawalNonce, bool forceBatch);
    event Received(uint256 fromDerive, uint256 unexpected);
    event StateChanged(State from, State to);
    event CheckpointRecorded(uint64 timestamp, uint256 pps);

    error NotAuthorized();
    error AlreadySeeded();
    error NotSeeded();
    error ZeroAmount();
    error BelowMinimum();
    error AboveTvlCap();
    error DepositsDisabled();
    error NoClosedRound();
    error RoundAwaitingProcessing();
    error ReportBeforeCutoff();
    error ReportNotLatest();
    error OptionsOpen();
    error UnknownReport();
    error NavBelowLiabilities();
    error FeesExceedNav();
    error NotOpenRound();
    error NoSuchRequest();
    error TooManyPendingRequests();
    error ExceedsClaimable();
    error ReserveShort();
    error ExceedsBuffer();
    error ExceedsWithdrawalCap();
    error InvalidParams();
    error PreviewDisabled();
    error UpgradeFrozen();
    error NoDrawdown();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    struct InitArgs {
        IERC20 asset;
        string name;
        string symbol;
        address governance;
        address admin;
        address guardian;
        address keeper;
        address feeCollector;
        Schedule schedule;
        FeeParams fees;
        SwingParams swing;
        BufferParams buffer;
        BreakerParams breaker;
        uint256 minDeposit;
        uint256 minRedeem;
        uint256 tvlCap;
        uint128 deriveMaxFeeUsdE18;
    }

    function initialize(InitArgs calldata a) external initializer {
        __ERC20_init(a.name, a.symbol);
        __AccessControl_init();
        __ReentrancyGuard_init();
        _asset = a.asset;
        _scale = 10 ** (36 - IERC20Metadata(address(a.asset)).decimals());
        feeCollector = a.feeCollector;
        upgradeFreezeUntil = uint64(block.timestamp + UPGRADE_FREEZE);
        _setSchedule(a.schedule);
        _setFees(a.fees);
        _setSwing(a.swing);
        _setBuffer(a.buffer);
        _setBreaker(a.breaker);
        minDeposit = a.minDeposit;
        minRedeem = a.minRedeem;
        tvlCap = a.tvlCap;
        deriveMaxFeeUsdE18 = a.deriveMaxFeeUsdE18;
        _grantRole(DEFAULT_ADMIN_ROLE, a.governance);
        _grantRole(GOVERNANCE_ROLE, a.governance);
        _grantRole(ADMIN_ROLE, a.admin);
        _grantRole(GUARDIAN_ROLE, a.guardian);
        _grantRole(KEEPER_ROLE, a.keeper);
    }

    /// @notice Wires the oracle and the account module, seeds the vault and creates the Derive subaccount. Once.
    /// @dev Seed shares go to a dead address, so the first real depositor can't be diluted by rounding.
    function seed(NavOracle oracle_, DeriveAccountModule module_, uint256 assets) external onlyRole(ADMIN_ROLE) {
        if (seeded) revert AlreadySeeded();
        if (assets == 0) revert ZeroAmount();
        seeded = true;
        oracle = oracle_;
        module = module_;
        _asset.safeTransferFrom(msg.sender, address(module_), assets);
        module_.createSubaccount(assets);
        _mint(DEAD, assets.mulDiv(_scale, WAD));
        lastPps = WAD;
        lastNavPost = assets;
        hwm = WAD;
        lastCrystallizedAt = uint64(block.timestamp);
        openRound = 1;
        _rounds[1].cutoff = nextCutoff(block.timestamp);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Requests (ERC-7540)
    // ---------------------------------------------------------------------------------------------------------------

    function requestDeposit(uint256 assets, address controller, address owner)
        external
        nonReentrant
        returns (uint256 requestId)
    {
        _requireSeeded();
        if (owner != msg.sender && !isOperator[owner][msg.sender]) revert NotAuthorized();
        if (state != State.ACTIVE) revert DepositsDisabled();
        if (assets < minDeposit || assets == 0) revert BelowMinimum();
        if (lastNavPost + idlePending + assets > tvlCap) revert AboveTvlCap();
        _sync();
        _settle(controller);
        uint32 r = openRound;
        _addToSlot(_depositSlots[controller], r, assets);
        _rounds[r].pendingAssets += assets;
        idlePending += assets;
        _asset.safeTransferFrom(owner, address(this), assets);
        emit DepositRequest(controller, owner, r, msg.sender, assets);
        return r;
    }

    function requestRedeem(uint256 shares, address controller, address owner)
        external
        nonReentrant
        returns (uint256 requestId)
    {
        _requireSeeded();
        if (owner != msg.sender && !isOperator[owner][msg.sender]) _spendAllowance(owner, msg.sender, shares);
        if (shares < minRedeem || shares == 0) revert BelowMinimum();
        _sync();
        _settle(controller);
        uint32 r = openRound;
        _addToSlot(_redeemSlots[controller], r, shares);
        _rounds[r].pendingShares += shares;
        _transfer(owner, address(this), shares);
        emit RedeemRequest(controller, owner, r, msg.sender, shares);
        return r;
    }

    function cancelDepositRequest(uint256 requestId, address controller, address receiver) external nonReentrant {
        _checkController(controller);
        _sync();
        if (requestId != openRound) revert NotOpenRound();
        uint256 assets = _takeSlot(_depositSlots[controller], uint32(requestId));
        _rounds[uint32(requestId)].pendingAssets -= assets;
        idlePending -= assets;
        _asset.safeTransfer(receiver, assets);
        emit DepositRequestCanceled(controller, requestId, receiver, assets);
    }

    function cancelRedeemRequest(uint256 requestId, address controller, address receiver) external nonReentrant {
        _checkController(controller);
        _sync();
        if (requestId != openRound) revert NotOpenRound();
        uint256 shares = _takeSlot(_redeemSlots[controller], uint32(requestId));
        _rounds[uint32(requestId)].pendingShares -= shares;
        _transfer(address(this), receiver, shares);
        emit RedeemRequestCanceled(controller, requestId, receiver, shares);
    }

    function setOperator(address operator, bool approved) external returns (bool) {
        isOperator[msg.sender][operator] = approved;
        emit OperatorSet(msg.sender, operator, approved);
        return true;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Claims
    // ---------------------------------------------------------------------------------------------------------------

    function deposit(uint256 assets, address receiver, address controller)
        public
        nonReentrant
        returns (uint256 shares)
    {
        _checkController(controller);
        _settle(controller);
        Claimable storage c = _claimable[controller];
        if (assets > c.depositAssets) revert ExceedsClaimable();
        shares = assets == c.depositAssets ? c.shares : assets.mulDiv(c.shares, c.depositAssets);
        c.depositAssets -= assets;
        c.shares -= shares;
        _transfer(address(this), receiver, shares);
        emit Deposit(controller, receiver, assets, shares);
    }

    function deposit(uint256 assets, address receiver) external returns (uint256) {
        return deposit(assets, receiver, msg.sender);
    }

    function mint(uint256 shares, address receiver, address controller) public nonReentrant returns (uint256 assets) {
        _checkController(controller);
        _settle(controller);
        Claimable storage c = _claimable[controller];
        if (shares > c.shares) revert ExceedsClaimable();
        assets = shares == c.shares ? c.depositAssets : shares.mulDiv(c.depositAssets, c.shares, Math.Rounding.Ceil);
        if (assets > c.depositAssets) assets = c.depositAssets;
        c.depositAssets -= assets;
        c.shares -= shares;
        _transfer(address(this), receiver, shares);
        emit Deposit(controller, receiver, assets, shares);
    }

    function mint(uint256 shares, address receiver) external returns (uint256) {
        return mint(shares, receiver, msg.sender);
    }

    function redeem(uint256 shares, address receiver, address controller)
        external
        nonReentrant
        returns (uint256 assets)
    {
        _checkController(controller);
        _settle(controller);
        Claimable storage c = _claimable[controller];
        if (shares > c.redeemShares) revert ExceedsClaimable();
        assets = shares == c.redeemShares ? c.assets : shares.mulDiv(c.assets, c.redeemShares);
        _payOut(c, shares, assets, receiver, controller);
    }

    function withdraw(uint256 assets, address receiver, address controller)
        external
        nonReentrant
        returns (uint256 shares)
    {
        _checkController(controller);
        _settle(controller);
        Claimable storage c = _claimable[controller];
        if (assets > c.assets) revert ExceedsClaimable();
        shares = assets == c.assets ? c.redeemShares : assets.mulDiv(c.redeemShares, c.assets, Math.Rounding.Ceil);
        if (shares > c.redeemShares) shares = c.redeemShares;
        _payOut(c, shares, assets, receiver, controller);
    }

    /// @notice Returns deposits that were refunded because the vault wasn't ACTIVE when their round was processed.
    function claimRefund(address controller, address receiver) external nonReentrant returns (uint256 assets) {
        _checkController(controller);
        _settle(controller);
        assets = _claimable[controller].refund;
        if (assets == 0) revert ZeroAmount();
        _claimable[controller].refund = 0;
        refundReserve -= assets;
        _asset.safeTransfer(receiver, assets);
        emit RefundClaimed(controller, receiver, assets);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Processing (spec 01 §4)
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Prices and settles the oldest closed round with an accepted NAV report taken after its cutoff.
    /// @param reportId must be the oracle's latest accepted report, so the price can't be cherry-picked.
    function processRound(uint64 reportId) external nonReentrant {
        _requireSeeded();
        _sync();
        uint32 r = lastProcessed + 1;
        if (r >= openRound) revert NoClosedRound();
        Round storage R = _rounds[r];

        (uint64 latestId, NavOracle.Accepted memory a) = oracle.latest();
        if (reportId != latestId) revert ReportNotLatest();
        if (a.timestamp == 0) revert UnknownReport();
        if (a.timestamp < R.cutoff) revert ReportBeforeCutoff();
        if (schedule.requireFlatOptions && a.optionCount != 0) revert OptionsOpen();

        uint256 oracleNav = a.navAsset + buffer + _inTransitIn(a) + _inFlightOut(a);
        if (oracleNav < reserveUnfunded) revert NavBelowLiabilities();
        uint256 navPre = oracleNav - reserveUnfunded;

        bool hasFlows = R.pendingAssets != 0 || R.pendingShares != 0;
        uint256 feeShares = _crystallize(navPre, hasFlows);
        uint256 supply = totalSupply();
        uint256 pps = supply == 0 ? WAD : navPre.mulDiv(_scale, supply);
        if (feeShares != 0 && pps > hwm) hwm = pps;

        (uint256 depositPrice, uint256 redeemPrice) = _prices(R, navPre, pps);
        bool refundDeposits = state != State.ACTIVE;

        uint256 navPost = navPre;
        uint256 minted;
        if (R.pendingAssets != 0) {
            idlePending -= R.pendingAssets;
            if (refundDeposits) {
                refundReserve += R.pendingAssets;
            } else {
                minted = R.pendingAssets.mulDiv(_scale, depositPrice);
                _mint(address(this), minted);
                buffer += R.pendingAssets;
                navPost += R.pendingAssets;
            }
        }

        uint256 owed;
        if (R.pendingShares != 0) {
            owed = R.pendingShares.mulDiv(redeemPrice, _scale);
            _burn(address(this), R.pendingShares);
            navPost -= owed;
            uint256 fromBuffer = owed < buffer ? owed : buffer;
            buffer -= fromBuffer;
            reserveFunded += fromBuffer;
            reserveUnfunded += owed - fromBuffer;
        }

        R.processedAt = uint64(block.timestamp);
        R.navReportId = reportId;
        R.navPre = navPre;
        R.pps = pps;
        R.depositPrice = depositPrice;
        R.redeemPrice = redeemPrice;
        R.sharesMinted = minted;
        R.assetsOwed = owed;
        R.feeShares = feeShares;
        R.depositsRefunded = refundDeposits && R.pendingAssets != 0;

        lastProcessed = r;
        lastPps = pps;
        lastNavPost = navPost;
        _rounds[openRound].cutoff = nextCutoff(block.timestamp);

        emit RoundProcessed(
            r, reportId, navPre, pps, depositPrice, redeemPrice, minted, owed, feeShares, R.depositsRefunded
        );
    }

    function _crystallize(uint256 navPre, bool hasFlows) internal returns (uint256 feeShares) {
        uint256 supply = totalSupply();
        if (supply == 0) return 0;
        if (!hasFlows && block.timestamp < lastCrystallizedAt + fees.crystallizeMaxInterval) return 0;

        uint256 elapsed = block.timestamp - lastCrystallizedAt;
        uint256 paused = pausedAccum + (state == State.PAUSED ? block.timestamp - pausedSince : 0);
        uint256 active = elapsed > paused ? elapsed - paused : 0;

        uint256 mgmt = navPre.mulDiv(uint256(fees.mgmtFee) * active, WAD * YEAR);
        uint256 ppsGross = (navPre - mgmt).mulDiv(_scale, supply);
        uint256 perf;
        if (ppsGross > hwm) perf = (ppsGross - hwm).mulDiv(supply, _scale).mulDiv(fees.perfFee, WAD);
        uint256 total = mgmt + perf;
        if (total >= navPre) revert FeesExceedNav();

        lastCrystallizedAt = uint64(block.timestamp);
        pausedAccum = 0;
        if (state == State.PAUSED) pausedSince = uint64(block.timestamp);

        if (total == 0) return 0;
        feeShares = total.mulDiv(supply, navPre - total);
        _mint(feeCollector, feeShares);
        emit FeesCrystallized(mgmt, perf, feeShares, hwm);
    }

    function _prices(Round storage R, uint256 navPre, uint256 pps)
        internal
        view
        returns (uint256 depositPrice, uint256 redeemPrice)
    {
        uint256 outAssets = R.pendingShares.mulDiv(pps, _scale);
        uint256 net = R.pendingAssets > outAssets ? R.pendingAssets - outAssets : outAssets - R.pendingAssets;
        bool large = net.mulDiv(WAD, navPre) > swing.largeFlow;
        uint256 sIn = large ? swing.inLarge : swing.inNormal;
        uint256 sOut = large ? swing.outLarge : swing.outNormal;
        depositPrice = pps.mulDiv(WAD + sIn, WAD);
        redeemPrice = pps.mulDiv(WAD - sOut, WAD);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Liquidity (spec 01 §6)
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Moves free buffer into the Derive account. Not allowed while a closed round awaits its price.
    function sendToDerive(uint256 amount) external nonReentrant onlyRole(KEEPER_ROLE) {
        _sync();
        if (openRound != lastProcessed + 1) revert RoundAwaitingProcessing();
        if (amount == 0) revert ZeroAmount();
        if (amount > buffer) revert ExceedsBuffer();
        buffer -= amount;
        _asset.safeTransfer(address(module), amount);
        uint64 nonce = module.depositToDerive(amount);
        emit SentToDerive(amount, nonce);
    }

    /// @notice Asks the account module to withdraw from Derive to this vault, up to what reserves and the buffer need.
    function requestDeriveWithdrawal(uint256 amount, bool forceBatch) external nonReentrant onlyRole(KEEPER_ROLE) {
        _sync();
        if (openRound != lastProcessed + 1) revert RoundAwaitingProcessing();
        if (amount == 0) revert ZeroAmount();
        if (amount > maxDeriveWithdrawal()) revert ExceedsWithdrawalCap();
        uint64 nonce = module.withdrawToVault(amount, deriveMaxFeeUsdE18, forceBatch);
        emit DeriveWithdrawalRequested(amount, nonce, forceBatch);
    }

    /// @notice Most the keeper may currently withdraw from Derive: unfunded redemptions plus the buffer shortfall,
    ///         minus withdrawals already requested and not yet received.
    function maxDeriveWithdrawal() public view returns (uint256) {
        uint256 target = lastNavPost.mulDiv(bufferParams.target, WAD);
        uint256 need = reserveUnfunded + (target > buffer ? target - buffer : 0);
        uint256 requested = module.cumulativeWithdrawn(module.withdrawalNonce());
        uint256 outstanding = requested > cumulativeReceived ? requested - cumulativeReceived : 0;
        return need > outstanding ? need - outstanding : 0;
    }

    /// @notice Books assets that arrived from Derive (or anywhere else) into the right bucket. Permissionless.
    function syncReceived() external nonReentrant {
        uint256 tracked = idlePending + reserveFunded + buffer + refundReserve;
        uint256 balance = _asset.balanceOf(address(this));
        if (balance <= tracked) return;
        uint256 surplus = balance - tracked;
        uint256 requested = module.cumulativeWithdrawn(module.withdrawalNonce());
        uint256 outstanding = requested > cumulativeReceived ? requested - cumulativeReceived : 0;
        uint256 fromDerive = surplus < outstanding ? surplus : outstanding;
        cumulativeReceived += fromDerive;
        uint256 toReserve = surplus < reserveUnfunded ? surplus : reserveUnfunded;
        reserveUnfunded -= toReserve;
        reserveFunded += toReserve;
        buffer += surplus - toReserve;
        emit Received(fromDerive, surplus - fromDerive);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Breaker (spec 05 §4)
    // ---------------------------------------------------------------------------------------------------------------

    function checkpoint() external {
        _requireSeeded();
        Checkpoint storage last = _checkpoints[_checkpointIndex];
        if (last.timestamp != 0 && block.timestamp < last.timestamp + breakerParams.checkpointInterval) return;
        uint256 pps = midPps();
        _checkpointIndex = uint8((_checkpointIndex + 1) % CHECKPOINTS);
        _checkpoints[_checkpointIndex] = Checkpoint(uint64(block.timestamp), uint192(pps));
        emit CheckpointRecorded(uint64(block.timestamp), pps);
    }

    function triggerBreaker() external {
        uint256 pps = midPps();
        uint256 peak = pps;
        uint256 from = block.timestamp > breakerParams.window ? block.timestamp - breakerParams.window : 0;
        for (uint256 i; i < CHECKPOINTS; ++i) {
            Checkpoint storage c = _checkpoints[i];
            if (c.timestamp >= from && c.pps > peak) peak = c.pps;
        }
        if (pps >= peak.mulDiv(WAD - breakerParams.drawdownThreshold, WAD)) revert NoDrawdown();
        if (state == State.ACTIVE) _setState(State.REDUCE_ONLY);
    }

    /// @notice Share price from the latest accepted report, net of liabilities (haircut applied by the oracle).
    function midPps() public view returns (uint256) {
        (, NavOracle.Accepted memory a) = oracle.latest();
        uint256 nav = a.navAsset + buffer + _inTransitIn(a) + _inFlightOut(a);
        nav = nav > reserveUnfunded ? nav - reserveUnfunded : 0;
        uint256 supply = totalSupply(); // shares queued for redemption still own their part until processed
        return supply == 0 ? lastPps : nav.mulDiv(_scale, supply);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // State and governance
    // ---------------------------------------------------------------------------------------------------------------

    function setReduceOnly() external onlyRole(GUARDIAN_ROLE) {
        if (state == State.ACTIVE) _setState(State.REDUCE_ONLY);
    }

    function setPaused() external onlyRole(GUARDIAN_ROLE) {
        if (state != State.PAUSED) _setState(State.PAUSED);
    }

    /// @notice Back to ACTIVE. Owner multisig, no timelock: it restores parameters that already passed the timelock.
    function resume() external onlyRole(ADMIN_ROLE) {
        if (state != State.ACTIVE) _setState(State.ACTIVE);
    }

    function setSchedule(Schedule calldata s) external onlyRole(GOVERNANCE_ROLE) {
        _setSchedule(s);
    }

    function setFees(FeeParams calldata f) external onlyRole(GOVERNANCE_ROLE) {
        _setFees(f);
    }

    function setSwing(SwingParams calldata s) external onlyRole(GOVERNANCE_ROLE) {
        _setSwing(s);
    }

    function setBuffer(BufferParams calldata b) external onlyRole(GOVERNANCE_ROLE) {
        _setBuffer(b);
    }

    function setBreaker(BreakerParams calldata b) external onlyRole(GOVERNANCE_ROLE) {
        _setBreaker(b);
    }

    function setLimits(uint256 minDeposit_, uint256 minRedeem_, uint256 tvlCap_) external onlyRole(GOVERNANCE_ROLE) {
        minDeposit = minDeposit_;
        minRedeem = minRedeem_;
        tvlCap = tvlCap_;
    }

    /// @notice Lowering the TVL cap is risk-reducing, so the guardian may do it immediately.
    function lowerTvlCap(uint256 tvlCap_) external onlyRole(GUARDIAN_ROLE) {
        if (tvlCap_ >= tvlCap) revert InvalidParams();
        tvlCap = tvlCap_;
    }

    function setFeeCollector(address feeCollector_) external onlyRole(GOVERNANCE_ROLE) {
        feeCollector = feeCollector_;
    }

    function setDeriveMaxFee(uint128 maxFeeUsdE18) external onlyRole(GOVERNANCE_ROLE) {
        deriveMaxFeeUsdE18 = maxFeeUsdE18;
    }

    function _authorizeUpgrade(address) internal view override onlyRole(GOVERNANCE_ROLE) {
        if (block.timestamp < upgradeFreezeUntil) revert UpgradeFrozen();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // ERC-4626 / ERC-7540 views
    // ---------------------------------------------------------------------------------------------------------------

    function asset() external view returns (address) {
        return address(_asset);
    }

    function share() external view returns (address) {
        return address(this);
    }

    /// @notice NAV as of the last processed round.
    function totalAssets() external view returns (uint256) {
        return lastNavPost;
    }

    function convertToShares(uint256 assets) external view returns (uint256) {
        return assets.mulDiv(_scale, lastPps);
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        return shares.mulDiv(lastPps, _scale);
    }

    function previewDeposit(uint256) external pure returns (uint256) {
        revert PreviewDisabled();
    }

    function previewMint(uint256) external pure returns (uint256) {
        revert PreviewDisabled();
    }

    function previewRedeem(uint256) external pure returns (uint256) {
        revert PreviewDisabled();
    }

    function previewWithdraw(uint256) external pure returns (uint256) {
        revert PreviewDisabled();
    }

    function maxDeposit(address controller) external view returns (uint256) {
        return _viewClaimable(controller).depositAssets;
    }

    function maxMint(address controller) external view returns (uint256) {
        return _viewClaimable(controller).shares;
    }

    function maxRedeem(address controller) external view returns (uint256) {
        Claimable memory c = _viewClaimable(controller);
        if (c.assets <= reserveFunded) return c.redeemShares;
        return reserveFunded.mulDiv(c.redeemShares, c.assets);
    }

    function maxWithdraw(address controller) external view returns (uint256) {
        Claimable memory c = _viewClaimable(controller);
        return c.assets < reserveFunded ? c.assets : reserveFunded;
    }

    function pendingDepositRequest(uint256 requestId, address controller) external view returns (uint256) {
        return _pending(_depositSlots[controller], requestId);
    }

    function pendingRedeemRequest(uint256 requestId, address controller) external view returns (uint256) {
        return _pending(_redeemSlots[controller], requestId);
    }

    /// @dev Claims are aggregated per controller, so `requestId` is ignored for claimable amounts (ERC-7540 allows it).
    function claimableDepositRequest(uint256, address controller) external view returns (uint256) {
        return _viewClaimable(controller).depositAssets;
    }

    function claimableRedeemRequest(uint256, address controller) external view returns (uint256) {
        return _viewClaimable(controller).redeemShares;
    }

    function claimableRefund(address controller) external view returns (uint256) {
        return _viewClaimable(controller).refund;
    }

    function rounds(uint32 r) external view returns (Round memory) {
        return _rounds[r];
    }

    /// @notice The first scheduled cutoff strictly after `t`.
    function nextCutoff(uint256 t) public view returns (uint64) {
        uint256 period = schedule.period;
        uint256 offset = schedule.offset;
        if (t < offset) return uint64(offset);
        return uint64(offset + ((t - offset) / period + 1) * period);
    }

    function supportsInterface(bytes4 id) public view override returns (bool) {
        return id == 0xe3bc4e65 // ERC-7540 operator
            || id == 0xce3bbe50 // ERC-7540 async deposit
            || id == 0x620ee8e4 // ERC-7540 async redeem
            || id == 0x2f0a18c5 // ERC-7575
            || super.supportsInterface(id);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Closes the open round once its cutoff has passed. A new round's cutoff is only set when the previous round
    ///      is processed, so at most two rounds are ever unprocessed: one closed, one open.
    function _sync() internal {
        Round storage o = _rounds[openRound];
        if (openRound == lastProcessed + 1 && o.cutoff != 0 && block.timestamp >= o.cutoff) {
            emit RoundClosed(openRound, o.cutoff);
            openRound += 1;
        }
    }

    function _settle(address controller) internal {
        Claimable storage c = _claimable[controller];
        Slot[2] storage ds = _depositSlots[controller];
        Slot[2] storage rs = _redeemSlots[controller];
        for (uint256 i; i < 2; ++i) {
            Slot storage s = ds[i];
            if (s.round != 0 && s.round <= lastProcessed) {
                Round storage R = _rounds[s.round];
                if (R.depositsRefunded) {
                    c.refund += s.amount;
                } else {
                    c.depositAssets += s.amount;
                    c.shares += s.amount.mulDiv(_scale, R.depositPrice);
                }
                delete ds[i];
            }
            Slot storage t = rs[i];
            if (t.round != 0 && t.round <= lastProcessed) {
                c.redeemShares += t.amount;
                c.assets += t.amount.mulDiv(_rounds[t.round].redeemPrice, _scale);
                delete rs[i];
            }
        }
    }

    function _viewClaimable(address controller) internal view returns (Claimable memory c) {
        c = _claimable[controller];
        Slot[2] storage ds = _depositSlots[controller];
        Slot[2] storage rs = _redeemSlots[controller];
        for (uint256 i; i < 2; ++i) {
            Slot storage s = ds[i];
            if (s.round != 0 && s.round <= lastProcessed) {
                Round storage R = _rounds[s.round];
                if (R.depositsRefunded) {
                    c.refund += s.amount;
                } else {
                    c.depositAssets += s.amount;
                    c.shares += s.amount.mulDiv(_scale, R.depositPrice);
                }
            }
            Slot storage t = rs[i];
            if (t.round != 0 && t.round <= lastProcessed) {
                c.redeemShares += t.amount;
                c.assets += t.amount.mulDiv(_rounds[t.round].redeemPrice, _scale);
            }
        }
    }

    function _addToSlot(Slot[2] storage slots, uint32 round, uint256 amount) internal {
        for (uint256 i; i < 2; ++i) {
            if (slots[i].round == round) {
                slots[i].amount += amount;
                return;
            }
        }
        for (uint256 i; i < 2; ++i) {
            if (slots[i].round == 0) {
                slots[i] = Slot(round, amount);
                return;
            }
        }
        revert TooManyPendingRequests();
    }

    function _takeSlot(Slot[2] storage slots, uint32 round) internal returns (uint256 amount) {
        for (uint256 i; i < 2; ++i) {
            if (slots[i].round == round && slots[i].amount != 0) {
                amount = slots[i].amount;
                delete slots[i];
                return amount;
            }
        }
        revert NoSuchRequest();
    }

    function _pending(Slot[2] storage slots, uint256 requestId) internal view returns (uint256) {
        if (requestId <= lastProcessed) return 0;
        for (uint256 i; i < 2; ++i) {
            if (slots[i].round == requestId) return slots[i].amount;
        }
        return 0;
    }

    function _payOut(Claimable storage c, uint256 shares, uint256 assets, address receiver, address controller)
        internal
    {
        if (assets > reserveFunded) revert ReserveShort();
        c.redeemShares -= shares;
        c.assets -= assets;
        reserveFunded -= assets;
        _asset.safeTransfer(receiver, assets);
        emit Withdraw(msg.sender, receiver, controller, assets, shares);
    }

    function _inTransitIn(NavOracle.Accepted memory a) internal view returns (uint256) {
        return module.depositsInTransit(a.lastCreditedDeposit);
    }

    function _inFlightOut(NavOracle.Accepted memory a) internal view returns (uint256) {
        uint64 n = module.withdrawalNonce();
        uint64 applied = a.lastAppliedWithdrawal < n ? a.lastAppliedWithdrawal : n;
        uint256 debited = module.cumulativeWithdrawn(applied);
        return debited > cumulativeReceived ? debited - cumulativeReceived : 0;
    }

    function _checkController(address controller) internal view {
        if (controller != msg.sender && !isOperator[controller][msg.sender]) revert NotAuthorized();
    }

    function _requireSeeded() internal view {
        if (!seeded) revert NotSeeded();
    }

    function _setState(State next) internal {
        State prev = state;
        if (prev == State.PAUSED) pausedAccum += uint64(block.timestamp) - pausedSince;
        if (next == State.PAUSED) pausedSince = uint64(block.timestamp);
        state = next;
        emit StateChanged(prev, next);
    }

    function _setSchedule(Schedule memory s) internal {
        if (s.period == 0 || s.offset >= s.period) revert InvalidParams();
        schedule = s;
    }

    function _setFees(FeeParams memory f) internal {
        if (f.mgmtFee > MAX_MGMT_FEE || f.perfFee > MAX_PERF_FEE || f.crystallizeMaxInterval == 0) {
            revert InvalidParams();
        }
        fees = f;
    }

    function _setSwing(SwingParams memory s) internal {
        if (s.inNormal > MAX_SWING || s.outNormal > MAX_SWING || s.inLarge > MAX_SWING || s.outLarge > MAX_SWING) {
            revert InvalidParams();
        }
        swing = s;
    }

    function _setBuffer(BufferParams memory b) internal {
        if (b.min > b.target || b.target > b.max || b.max > MAX_BUFFER) revert InvalidParams();
        bufferParams = b;
    }

    function _setBreaker(BreakerParams memory b) internal {
        if (b.drawdownThreshold == 0 || b.drawdownThreshold >= WAD || b.window == 0 || b.checkpointInterval == 0) {
            revert InvalidParams();
        }
        breakerParams = b;
    }
}
