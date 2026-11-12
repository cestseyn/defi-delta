// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IChainlinkAggregator} from "./interfaces/IChainlinkAggregator.sol";
import {DeriveFeedLib} from "./libraries/DeriveFeedLib.sol";
import {DeriveAccountModule} from "./DeriveAccountModule.sol";

/// @title NavOracle
/// @notice Accepts attested snapshots of the vault's Derive account and turns them into a NAV in the vault's asset
///         (spec 02). Phase 1 prices option positions at the attested Derive mark; at a weekly round no options are
///         open, so the NAV used for pricing shares depends only on balances and the verified spot price.
contract NavOracle is Initializable, UUPSUpgradeable, AccessControlUpgradeable, EIP712Upgradeable {
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    uint256 internal constant WAD = 1e18;

    bytes32 public constant REPORT_TYPEHASH = keccak256(
        "NavReport(uint64 reportId,uint64 timestamp,uint64 subaccountId,int256 cash,uint256 baseQty,int256 perpQty,"
        "int256 perpUnsettled,int256 optionsValue,uint32 optionCount,int256 deriveMtm,uint64 lastCreditedDeposit,"
        "uint64 lastAppliedWithdrawal,bytes32 spotFeedHash)"
    );

    enum AssetUnit {
        ETH, // vault asset is WETH: NAV is converted at the verified spot
        USD // vault asset is a USD stablecoin: NAV is taken at 1:1
    }

    /// @notice Attested snapshot of the Derive subaccount. USD amounts and quantities are 18-decimal.
    struct Report {
        uint64 reportId;
        uint64 timestamp;
        uint64 subaccountId;
        int256 cash; // USDC balance incl. accrued interest
        uint256 baseQty; // ETH spot asset held
        int256 perpQty; // ETH perp size, + = long
        int256 perpUnsettled; // unrealized perp PnL + unsettled funding
        int256 optionsValue; // Σ q·mark of open options (negative when short)
        uint32 optionCount; // number of open option positions
        int256 deriveMtm; // Derive risk-engine MtM of the subaccount
        uint64 lastCreditedDeposit; // module deposit nonce reflected in the balances
        uint64 lastAppliedWithdrawal; // module withdrawal nonce already debited on Derive
        bytes spotFeed; // ABI-encoded Derive-signed spot FeedData
    }

    struct Accepted {
        uint64 timestamp;
        uint32 optionCount;
        uint64 lastCreditedDeposit;
        uint64 lastAppliedWithdrawal;
        uint256 navAsset; // value of the Derive account in the vault asset's units
        uint256 spot; // verified ETH spot, 18-decimal USD
        int256 flowAdjusted; // navAsset − assets credited in + assets debited out; flows don't move it
    }

    struct Params {
        uint64 navMaxAge; // a report must be at most this old when submitted
        uint64 feedMaxAge; // |feed.timestamp − report.timestamp|
        uint64 chainlinkMaxAge;
        uint64 maxSourceDeviation; // WAD; Derive spot vs Chainlink
        uint64 navTolerance; // WAD; own valuation vs deriveMtm
        uint64 navJumpTolerance; // WAD; continuity slack on top of the spot move
        uint64 optionHaircut; // WAD; extra liability on short options
    }

    AssetUnit public assetUnit;
    uint8 public assetDecimals;
    uint64 public subaccountId;
    DeriveAccountModule public module;
    IChainlinkAggregator public chainlink;
    bytes32 public spotFeedDomainSeparator;
    uint8 public deriveSignersRequired;
    uint8 public attesterThreshold;
    Params public params;

    mapping(address => bool) public isDeriveSigner;
    mapping(address => bool) public isAttester;

    uint64 public lastReportId;
    uint64 public latestReportId;
    mapping(uint64 => Accepted) internal _accepted;
    mapping(uint64 => Accepted) internal _held;

    event NavReportAccepted(
        uint64 indexed reportId, uint64 timestamp, uint256 navAsset, uint256 spot, uint32 optionCount
    );
    event NavReportHeld(uint64 indexed reportId, uint64 timestamp, uint256 navAsset, uint256 spot);
    event HeldReportConfirmed(uint64 indexed reportId);
    event AttesterSet(address indexed attester, bool allowed);
    event DeriveSignerSet(address indexed signer, bool allowed);
    event ParamsSet(Params params);

    error NotEnoughSignatures();
    error SignersNotSorted();
    error UnknownAttester(address signer);
    error StaleReport();
    error ReportFromFuture();
    error ReportIdNotIncreasing();
    error TimestampNotIncreasing();
    error WrongSubaccount();
    error ChainlinkStale();
    error ChainlinkInvalid();
    error SpotDeviation(uint256 deriveSpot, uint256 chainlinkSpot);
    error NavNonPositive();
    error MtmMismatch(int256 computed, int256 deriveMtm);
    error NotHeld();
    error InvalidParams();
    error ThresholdTooLow();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    struct InitArgs {
        AssetUnit assetUnit;
        uint8 assetDecimals;
        uint64 subaccountId;
        DeriveAccountModule module;
        IChainlinkAggregator chainlink;
        bytes32 spotFeedDomainSeparator;
        address[] deriveSigners;
        uint8 deriveSignersRequired;
        address[] attesters;
        uint8 attesterThreshold;
        Params params;
        address governance;
        address guardian;
    }

    function initialize(InitArgs calldata a) external initializer {
        __AccessControl_init();
        __EIP712_init("DeltaNavOracle", "1");
        if (a.attesterThreshold < 2 || a.deriveSignersRequired == 0) revert ThresholdTooLow();
        assetUnit = a.assetUnit;
        assetDecimals = a.assetDecimals;
        subaccountId = a.subaccountId;
        module = a.module;
        chainlink = a.chainlink;
        spotFeedDomainSeparator = a.spotFeedDomainSeparator;
        deriveSignersRequired = a.deriveSignersRequired;
        attesterThreshold = a.attesterThreshold;
        _setParams(a.params);
        for (uint256 i; i < a.deriveSigners.length; ++i) {
            isDeriveSigner[a.deriveSigners[i]] = true;
            emit DeriveSignerSet(a.deriveSigners[i], true);
        }
        for (uint256 i; i < a.attesters.length; ++i) {
            isAttester[a.attesters[i]] = true;
            emit AttesterSet(a.attesters[i], true);
        }
        _grantRole(DEFAULT_ADMIN_ROLE, a.governance);
        _grantRole(GOVERNANCE_ROLE, a.governance);
        _grantRole(GUARDIAN_ROLE, a.guardian);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Reports
    // ---------------------------------------------------------------------------------------------------------------

    /// @param signatures attester signatures over the EIP-712 report hash, ordered by strictly increasing signer.
    function submitReport(Report calldata r, bytes[] calldata signatures) external returns (bool isAccepted) {
        _checkHeader(r);
        _checkAttesters(reportDigest(r), signatures);

        uint256 spot = DeriveFeedLib.verifySpot(
            r.spotFeed, spotFeedDomainSeparator, isDeriveSigner, deriveSignersRequired, r.timestamp, params.feedMaxAge
        );
        _checkChainlink(spot);

        (int256 rawUsd, int256 navUsd) = _valueUsd(r, spot);
        if (navUsd <= 0) revert NavNonPositive();
        _checkMtm(rawUsd, r.deriveMtm);

        uint256 navAsset = _toAsset(uint256(navUsd), spot);
        Accepted memory a = Accepted({
            timestamp: r.timestamp,
            optionCount: r.optionCount,
            lastCreditedDeposit: r.lastCreditedDeposit,
            lastAppliedWithdrawal: r.lastAppliedWithdrawal,
            navAsset: navAsset,
            spot: spot,
            flowAdjusted: _flowAdjusted(navAsset, r.lastCreditedDeposit, r.lastAppliedWithdrawal)
        });
        lastReportId = r.reportId;

        if (_continuous(a)) {
            _accept(r.reportId, a);
            return true;
        }
        _held[r.reportId] = a;
        emit NavReportHeld(r.reportId, a.timestamp, a.navAsset, a.spot);
        return false;
    }

    /// @notice Guardian override for a report held by the continuity check (spec 02 §5).
    function confirmHeld(uint64 reportId) external onlyRole(GUARDIAN_ROLE) {
        Accepted memory a = _held[reportId];
        if (a.timestamp == 0) revert NotHeld();
        if (a.timestamp <= _accepted[latestReportId].timestamp) revert TimestampNotIncreasing();
        delete _held[reportId];
        _accept(reportId, a);
        emit HeldReportConfirmed(reportId);
    }

    function accepted(uint64 reportId) external view returns (Accepted memory) {
        return _accepted[reportId];
    }

    function latest() external view returns (uint64 reportId, Accepted memory report) {
        return (latestReportId, _accepted[latestReportId]);
    }

    function held(uint64 reportId) external view returns (Accepted memory) {
        return _held[reportId];
    }

    function reportDigest(Report calldata r) public view returns (bytes32) {
        // Standard EIP-712 struct hash. Every member is a static word, so encoding the two halves and concatenating
        // them equals abi.encode of the whole struct; splitting it only keeps the stack shallow.
        return _hashTypedDataV4(keccak256(bytes.concat(_headBytes(r), _tailBytes(r))));
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Governance
    // ---------------------------------------------------------------------------------------------------------------

    function setParams(Params calldata p) external onlyRole(GOVERNANCE_ROLE) {
        _setParams(p);
    }

    function setAttester(address attester, bool allowed) external {
        // Adding is governance-only; removing is risk-reducing and the guardian may do it.
        if (allowed || !hasRole(GUARDIAN_ROLE, msg.sender)) _checkRole(GOVERNANCE_ROLE);
        isAttester[attester] = allowed;
        emit AttesterSet(attester, allowed);
    }

    function setDeriveSigner(address signer, bool allowed) external {
        if (allowed || !hasRole(GUARDIAN_ROLE, msg.sender)) _checkRole(GOVERNANCE_ROLE);
        isDeriveSigner[signer] = allowed;
        emit DeriveSignerSet(signer, allowed);
    }

    function _authorizeUpgrade(address) internal override onlyRole(GOVERNANCE_ROLE) {}

    // ---------------------------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------------------------

    function _checkHeader(Report calldata r) internal view {
        if (r.reportId <= lastReportId) revert ReportIdNotIncreasing();
        if (r.timestamp > block.timestamp) revert ReportFromFuture();
        if (r.timestamp + params.navMaxAge < block.timestamp) revert StaleReport();
        if (r.timestamp <= _accepted[latestReportId].timestamp) revert TimestampNotIncreasing();
        if (r.subaccountId != subaccountId) revert WrongSubaccount();
    }

    function _checkAttesters(bytes32 digest, bytes[] calldata signatures) internal view {
        if (signatures.length < attesterThreshold) revert NotEnoughSignatures();
        address previous;
        for (uint256 i; i < signatures.length; ++i) {
            address signer = ECDSA.recover(digest, signatures[i]);
            if (signer <= previous) revert SignersNotSorted();
            if (!isAttester[signer]) revert UnknownAttester(signer);
            previous = signer;
        }
    }

    function _checkChainlink(uint256 spot) internal view {
        (, int256 answer,, uint256 updatedAt,) = chainlink.latestRoundData();
        if (answer <= 0) revert ChainlinkInvalid();
        if (updatedAt + params.chainlinkMaxAge < block.timestamp) revert ChainlinkStale();
        uint256 cl = uint256(answer) * 10 ** (18 - chainlink.decimals());
        uint256 diff = spot > cl ? spot - cl : cl - spot;
        if (Math.mulDiv(diff, WAD, cl) > params.maxSourceDeviation) revert SpotDeviation(spot, cl);
    }

    /// @return rawUsd value at Derive's marks (comparable with deriveMtm); navUsd the same with the option haircut.
    function _valueUsd(Report calldata r, uint256 spot) internal view returns (int256 rawUsd, int256 navUsd) {
        int256 base = int256(Math.mulDiv(r.baseQty, spot, WAD));
        rawUsd = r.cash + base + r.perpUnsettled + r.optionsValue;
        int256 options = r.optionsValue;
        if (options < 0) options -= int256(Math.mulDiv(uint256(-options), params.optionHaircut, WAD));
        navUsd = r.cash + base + r.perpUnsettled + options;
    }

    function _checkMtm(int256 rawUsd, int256 deriveMtm) internal view {
        uint256 diff = rawUsd > deriveMtm ? uint256(rawUsd - deriveMtm) : uint256(deriveMtm - rawUsd);
        uint256 scale = rawUsd > 0 ? uint256(rawUsd) : uint256(-rawUsd);
        if (diff > Math.mulDiv(scale, params.navTolerance, WAD)) revert MtmMismatch(rawUsd, deriveMtm);
    }

    function _toAsset(uint256 navUsd, uint256 spot) internal view returns (uint256) {
        uint256 price = assetUnit == AssetUnit.ETH ? spot : WAD;
        return Math.mulDiv(navUsd, 10 ** assetDecimals, price);
    }

    /// @dev Value may move by at most |ΔS/S| + navJumpTolerance since the last accepted report. Deposits into and
    ///      withdrawals from the account are netted out first, so moving assets doesn't look like a jump. In the vault's
    ///      own unit exposure is |δ − 1| for an ETH vault and |δ| for a USD vault, both ≤ 1, so |ΔS/S| bounds it.
    function _continuous(Accepted memory a) internal view returns (bool) {
        Accepted storage prev = _accepted[latestReportId];
        if (prev.timestamp == 0) return true;
        uint256 spotMove = _relDiff(a.spot, prev.spot);
        int256 delta = a.flowAdjusted - prev.flowAdjusted;
        // Relative to the larger of the two values, so assets credited in between don't inflate the ratio.
        uint256 base = a.navAsset > prev.navAsset ? a.navAsset : prev.navAsset;
        uint256 move = Math.mulDiv(delta < 0 ? uint256(-delta) : uint256(delta), WAD, base);
        return move <= spotMove + params.navJumpTolerance;
    }

    function _flowAdjusted(uint256 navAsset, uint64 creditedNonce, uint64 appliedNonce) internal view returns (int256) {
        uint256 credited = module.cumulativeDeposited(creditedNonce);
        uint256 debited = module.cumulativeWithdrawn(appliedNonce);
        return int256(navAsset) - int256(credited) + int256(debited);
    }

    function _accept(uint64 reportId, Accepted memory a) internal {
        _accepted[reportId] = a;
        latestReportId = reportId;
        emit NavReportAccepted(reportId, a.timestamp, a.navAsset, a.spot, a.optionCount);
    }

    function _setParams(Params memory p) internal {
        if (
            p.navMaxAge == 0 || p.feedMaxAge == 0 || p.chainlinkMaxAge == 0 || p.maxSourceDeviation > 0.05e18
                || p.navTolerance > 0.01e18 || p.navJumpTolerance > 0.03e18 || p.optionHaircut > 0.5e18
        ) revert InvalidParams();
        params = p;
        emit ParamsSet(p);
    }

    function _relDiff(uint256 x, uint256 ref) internal pure returns (uint256) {
        uint256 diff = x > ref ? x - ref : ref - x;
        return Math.mulDiv(diff, WAD, ref);
    }

    function _headBytes(Report calldata r) internal pure returns (bytes memory) {
        return abi.encode(REPORT_TYPEHASH, r.reportId, r.timestamp, r.subaccountId, r.cash, r.baseQty, r.perpQty);
    }

    function _tailBytes(Report calldata r) internal pure returns (bytes memory) {
        return abi.encode(
            r.perpUnsettled,
            r.optionsValue,
            r.optionCount,
            r.deriveMtm,
            r.lastCreditedDeposit,
            r.lastAppliedWithdrawal,
            keccak256(r.spotFeed)
        );
    }
}
