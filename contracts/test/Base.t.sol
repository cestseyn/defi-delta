// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {DeltaVault} from "../src/DeltaVault.sol";
import {NavOracle} from "../src/NavOracle.sol";
import {DeriveAccountModule} from "../src/DeriveAccountModule.sol";
import {DeriveFeedLib} from "../src/libraries/DeriveFeedLib.sol";
import {IChainlinkAggregator} from "../src/interfaces/IChainlinkAggregator.sol";
import {IOnchainActionManager} from "../src/interfaces/IOnchainActionManager.sol";
import {MockToken, MockActionManager, MockChainlink} from "./mocks/Mocks.sol";

/// @notice Shared fixture: a CC vault (asset WETH) wired to a mocked Derive action manager and real oracle.
abstract contract BaseTest is Test {
    uint64 internal constant MONDAY = 1794787200; // 2026-11-16 00:00 UTC
    uint64 internal constant FRIDAY_0800 = 1795161600; // 2026-11-20 08:00 UTC
    uint64 internal constant WEEK = 7 days;
    uint64 internal constant FRIDAY_OFFSET = 1 days + 8 hours; // Friday 08:00 UTC modulo one week
    uint64 internal constant SUBACCOUNT = 7;
    address internal constant SPOT_FEED_V2 = 0x727aD65db6aE99DB5Dbee8F202846DD6009bf6D5;
    uint256 internal constant SPOT = 2000e18;

    address internal governance = makeAddr("governance");
    address internal admin = makeAddr("admin");
    address internal guardian = makeAddr("guardian");
    address internal keeper = makeAddr("keeper");
    address internal feeCollector = makeAddr("feeCollector");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256[3] internal attesterKeys;
    address[3] internal attesters; // sorted ascending
    uint256[2] internal feedSignerKeys;
    address[2] internal feedSigners;

    MockToken internal weth;
    MockActionManager internal actionManager;
    MockChainlink internal chainlink;
    DeltaVault internal vault;
    NavOracle internal oracle;
    DeriveAccountModule internal module;
    bytes32 internal feedDomain;

    uint64 internal reportId;

    function setUp() public virtual {
        vm.warp(MONDAY);
        _makeKeys();

        weth = new MockToken("Wrapped Ether", "WETH", 18);
        actionManager = new MockActionManager(IERC20(address(weth)));
        chainlink = new MockChainlink();
        chainlink.set(int256(2000e8), block.timestamp);

        vault = DeltaVault(address(new ERC1967Proxy(address(new DeltaVault()), "")));
        vault.initialize(_vaultArgs(_weeklySchedule()));

        module = new DeriveAccountModule(
            IOnchainActionManager(address(actionManager)),
            IERC20(address(weth)),
            address(weth),
            1,
            address(vault),
            governance,
            guardian,
            admin
        );
        vm.deal(address(module), 1 ether);

        feedDomain = DeriveFeedLib.domainSeparator("LyraSpotFeed", "1", 957, SPOT_FEED_V2);
        oracle = NavOracle(address(new ERC1967Proxy(address(new NavOracle()), "")));
        oracle.initialize(_oracleArgs());
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Setup helpers
    // ---------------------------------------------------------------------------------------------------------------

    function _weeklySchedule() internal pure returns (DeltaVault.Schedule memory) {
        return DeltaVault.Schedule({period: WEEK, offset: FRIDAY_OFFSET, requireFlatOptions: true});
    }

    function _vaultArgs(DeltaVault.Schedule memory schedule) internal view returns (DeltaVault.InitArgs memory) {
        return DeltaVault.InitArgs({
            asset: IERC20(address(weth)),
            name: "Delta CC ETH",
            symbol: "dvETH-CC",
            governance: governance,
            admin: admin,
            guardian: guardian,
            keeper: keeper,
            feeCollector: feeCollector,
            schedule: schedule,
            fees: DeltaVault.FeeParams({mgmtFee: 0.02e18, perfFee: 0.15e18, crystallizeMaxInterval: 7 days}),
            swing: DeltaVault.SwingParams({inNormal: 0, outNormal: 0, inLarge: 0, outLarge: 0, largeFlow: 0.05e18}),
            buffer: DeltaVault.BufferParams({min: 0, target: 0, max: 0}),
            breaker: DeltaVault.BreakerParams({
                drawdownThreshold: 0.06e18, window: 1 days, checkpointInterval: 1 hours
            }),
            minDeposit: 0.01e18,
            minRedeem: 0.01e18,
            tvlCap: 10_000e18,
            deriveMaxFeeUsdE18: 10e18
        });
    }

    function _oracleArgs() internal view returns (NavOracle.InitArgs memory a) {
        address[] memory signers = new address[](2);
        signers[0] = feedSigners[0];
        signers[1] = feedSigners[1];
        address[] memory att = new address[](3);
        for (uint256 i; i < 3; ++i) {
            att[i] = attesters[i];
        }
        a = NavOracle.InitArgs({
            assetUnit: NavOracle.AssetUnit.ETH,
            assetDecimals: 18,
            subaccountId: SUBACCOUNT,
            module: module,
            chainlink: IChainlinkAggregator(address(chainlink)),
            spotFeedDomainSeparator: feedDomain,
            deriveSigners: signers,
            deriveSignersRequired: 2,
            attesters: att,
            attesterThreshold: 2,
            params: NavOracle.Params({
                navMaxAge: 10 minutes,
                feedMaxAge: 120,
                chainlinkMaxAge: 1 hours,
                maxSourceDeviation: 0.02e18,
                navTolerance: 0.0025e18,
                navJumpTolerance: 0.005e18,
                optionHaircut: 0.1e18
            }),
            governance: governance,
            guardian: guardian
        });
    }

    function _makeKeys() internal {
        for (uint256 i; i < 3; ++i) {
            attesterKeys[i] = uint256(keccak256(abi.encode("attester", i)));
            attesters[i] = vm.addr(attesterKeys[i]);
        }
        // sort ascending by address (bubble sort on three items)
        for (uint256 i; i < 3; ++i) {
            for (uint256 j; j + 1 < 3 - i; ++j) {
                if (attesters[j] > attesters[j + 1]) {
                    (attesters[j], attesters[j + 1]) = (attesters[j + 1], attesters[j]);
                    (attesterKeys[j], attesterKeys[j + 1]) = (attesterKeys[j + 1], attesterKeys[j]);
                }
            }
        }
        for (uint256 i; i < 2; ++i) {
            feedSignerKeys[i] = uint256(keccak256(abi.encode("feed", i)));
            feedSigners[i] = vm.addr(feedSignerKeys[i]);
        }
    }

    /// @notice Seeds the vault with `assets` and completes the module setup.
    function _seed(uint256 assets) internal {
        weth.mint(admin, assets);
        vm.startPrank(admin);
        weth.approve(address(vault), assets);
        vault.seed(oracle, module, assets);
        module.setSubaccountId(SUBACCOUNT);
        module.completeSetup();
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Report helpers
    // ---------------------------------------------------------------------------------------------------------------

    struct Snapshot {
        int256 cash;
        uint256 baseQty;
        int256 optionsValue;
        uint32 optionCount;
        uint64 lastCreditedDeposit;
        uint64 lastAppliedWithdrawal;
        uint256 spot;
    }

    function _flat(uint256 baseQty) internal view returns (Snapshot memory s) {
        s.baseQty = baseQty;
        s.lastCreditedDeposit = module.depositNonce();
        s.lastAppliedWithdrawal = module.withdrawalNonce();
        s.spot = SPOT;
    }

    function _spotFeed(uint256 price, uint64 timestamp) internal view returns (bytes memory) {
        DeriveFeedLib.FeedData memory f;
        f.data = abi.encode(uint96(price), uint64(1e18));
        f.deadline = timestamp + 1 hours;
        f.timestamp = timestamp;
        f.signers = new address[](2);
        f.signatures = new bytes[](2);
        bytes32 digest = MessageHashUtils.toTypedDataHash(feedDomain, DeriveFeedLib.hashFeedData(f));
        for (uint256 i; i < 2; ++i) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(feedSignerKeys[i], digest);
            f.signers[i] = feedSigners[i];
            f.signatures[i] = abi.encodePacked(r, s, v);
        }
        return abi.encode(f);
    }

    function _report(Snapshot memory s) internal returns (NavOracle.Report memory r) {
        int256 base = int256(s.baseQty * s.spot / 1e18);
        r = NavOracle.Report({
            reportId: ++reportId,
            timestamp: uint64(block.timestamp),
            subaccountId: SUBACCOUNT,
            cash: s.cash,
            baseQty: s.baseQty,
            perpQty: 0,
            perpUnsettled: 0,
            optionsValue: s.optionsValue,
            optionCount: s.optionCount,
            deriveMtm: s.cash + base + s.optionsValue,
            lastCreditedDeposit: s.lastCreditedDeposit,
            lastAppliedWithdrawal: s.lastAppliedWithdrawal,
            spotFeed: _spotFeed(s.spot, uint64(block.timestamp))
        });
    }

    function _sign(NavOracle.Report memory r, uint256 count) internal view returns (bytes[] memory sigs) {
        bytes32 digest = oracle.reportDigest(r);
        sigs = new bytes[](count);
        for (uint256 i; i < count; ++i) {
            (uint8 v, bytes32 rr, bytes32 ss) = vm.sign(attesterKeys[i], digest);
            sigs[i] = abi.encodePacked(rr, ss, v);
        }
    }

    function _submit(Snapshot memory s) internal returns (uint64 id) {
        if (s.spot != SPOT) chainlink.set(int256(s.spot / 1e10), block.timestamp);
        else chainlink.set(int256(2000e8), block.timestamp);
        NavOracle.Report memory r = _report(s);
        oracle.submitReport(r, _sign(r, 2));
        return r.reportId;
    }

    function _requestDeposit(address who, uint256 assets) internal returns (uint256 requestId) {
        weth.mint(who, assets);
        vm.startPrank(who);
        weth.approve(address(vault), assets);
        requestId = vault.requestDeposit(assets, who, who);
        vm.stopPrank();
    }
}
