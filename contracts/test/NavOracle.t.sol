// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {BaseTest} from "./Base.t.sol";
import {NavOracle} from "../src/NavOracle.sol";
import {DeriveFeedLib} from "../src/libraries/DeriveFeedLib.sol";

contract NavOracleTest is BaseTest {
    function setUp() public override {
        super.setUp();
        _seed(1e18);
    }

    function test_accepts_validReport() public {
        uint64 id = _submit(_flat(1e18));
        (uint64 latestId, NavOracle.Accepted memory a) = oracle.latest();
        assertEq(latestId, id);
        assertEq(a.navAsset, 1e18);
        assertEq(a.spot, SPOT);
    }

    function test_optionHaircut_appliesToShortOptions() public {
        Snapshot memory s = _flat(1e18);
        s.cash = 20e18; // premium received
        s.optionsValue = -10e18; // short calls marked at 10 USD
        s.optionCount = 1;
        _submit(s);
        (, NavOracle.Accepted memory a) = oracle.latest();
        // (2000 + 20 − 10·1.1) / 2000 WETH
        assertEq(a.navAsset, uint256(2009e18) * 1e18 / 2000e18);
    }

    function test_reverts_withOneSignature() public {
        NavOracle.Report memory r = _report(_flat(1e18));
        bytes[] memory sigs = _sign(r, 1);
        vm.expectRevert(NavOracle.NotEnoughSignatures.selector);
        oracle.submitReport(r, sigs);
    }

    function test_reverts_withUnsortedSignatures() public {
        NavOracle.Report memory r = _report(_flat(1e18));
        bytes[] memory sigs = _sign(r, 2);
        (sigs[0], sigs[1]) = (sigs[1], sigs[0]);
        vm.expectRevert(NavOracle.SignersNotSorted.selector);
        oracle.submitReport(r, sigs);
    }

    function test_reverts_withUnknownAttester() public {
        NavOracle.Report memory r = _report(_flat(1e18));
        bytes32 digest = oracle.reportDigest(r);
        bytes[] memory sigs = new bytes[](2);
        uint256 stranger = uint256(keccak256("stranger"));
        (uint8 v, bytes32 rr, bytes32 ss) = vm.sign(stranger, digest);
        (uint8 v2, bytes32 rr2, bytes32 ss2) = vm.sign(attesterKeys[0], digest);
        bool strangerFirst = vm.addr(stranger) < attesters[0];
        sigs[strangerFirst ? 0 : 1] = abi.encodePacked(rr, ss, v);
        sigs[strangerFirst ? 1 : 0] = abi.encodePacked(rr2, ss2, v2);
        vm.expectRevert(abi.encodeWithSelector(NavOracle.UnknownAttester.selector, vm.addr(stranger)));
        oracle.submitReport(r, sigs);
    }

    function test_reverts_whenFeedSignerUnknown() public {
        vm.prank(guardian);
        oracle.setDeriveSigner(feedSigners[1], false); // removal is risk-reducing: guardian may do it
        NavOracle.Report memory r = _report(_flat(1e18));
        bytes[] memory sigs = _sign(r, 2);
        vm.expectRevert(abi.encodeWithSelector(DeriveFeedLib.InvalidFeedSigner.selector, feedSigners[1]));
        oracle.submitReport(r, sigs);
    }

    function test_reverts_whenChainlinkDisagrees() public {
        chainlink.set(int256(2100e8), block.timestamp); // 5% away
        NavOracle.Report memory r = _report(_flat(1e18));
        bytes[] memory sigs = _sign(r, 2);
        vm.expectRevert(abi.encodeWithSelector(NavOracle.SpotDeviation.selector, SPOT, 2100e18));
        oracle.submitReport(r, sigs);
    }

    function test_reverts_whenReportStale() public {
        NavOracle.Report memory r = _report(_flat(1e18));
        bytes[] memory sigs = _sign(r, 2);
        vm.warp(block.timestamp + 11 minutes);
        chainlink.set(int256(2000e8), block.timestamp);
        vm.expectRevert(NavOracle.StaleReport.selector);
        oracle.submitReport(r, sigs);
    }

    function test_reverts_whenMtmDisagrees() public {
        NavOracle.Report memory r = _report(_flat(1e18));
        r.deriveMtm = 2100e18; // 5% off our own valuation
        bytes[] memory sigs = _sign(r, 2);
        vm.expectRevert(abi.encodeWithSelector(NavOracle.MtmMismatch.selector, int256(2000e18), int256(2100e18)));
        oracle.submitReport(r, sigs);
    }

    function test_holds_unexplainedJump_andGuardianConfirms() public {
        _submit(_flat(1e18));
        vm.warp(block.timestamp + 1 minutes);
        uint64 id = _submit(_flat(1.1e18)); // +10% with a flat spot: unexplained
        (uint64 latestId,) = oracle.latest();
        assertTrue(latestId != id);
        assertEq(oracle.held(id).navAsset, 1.1e18);

        vm.prank(guardian);
        oracle.confirmHeld(id);
        (latestId,) = oracle.latest();
        assertEq(latestId, id);
    }

    function test_onlyGovernanceAddsAttesters() public {
        vm.prank(guardian);
        vm.expectRevert();
        oracle.setAttester(alice, true);
        vm.prank(governance);
        oracle.setAttester(alice, true);
        assertTrue(oracle.isAttester(alice));
    }
}
