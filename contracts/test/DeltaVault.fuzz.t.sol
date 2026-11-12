// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {BaseTest} from "./Base.t.sol";
import {DeltaVault} from "../src/DeltaVault.sol";

/// @notice Flows at a round must never dilute existing holders, and claims must never exceed what the round created.
contract DeltaVaultFuzzTest is BaseTest {
    function setUp() public override {
        super.setUp();
        _seed(100e18);
    }

    function testFuzz_flowsDoNotDilute(uint96 depA, uint96 depB, uint16 redeemBps, uint64 gainBps) public {
        uint256 a = bound(uint256(depA), 0.01e18, 1000e18);
        uint256 b = bound(uint256(depB), 0.01e18, 1000e18);

        // Round 1: two deposits.
        _requestDeposit(alice, a);
        _requestDeposit(bob, b);
        vm.warp(FRIDAY_0800 + 10 minutes);
        vault.processRound(_submit(_flat(100e18)));
        DeltaVault.Round memory r1 = vault.rounds(1);
        uint256 claimA = vault.maxMint(alice);
        uint256 claimB = vault.maxMint(bob);
        vm.prank(alice);
        uint256 sa = vault.mint(claimA, alice, alice);
        vm.prank(bob);
        uint256 sb = vault.mint(claimB, bob, bob);
        assertLe(sa + sb, r1.sharesMinted, "claims exceed minted");

        // Move everything to Derive, then a gain or loss of up to ±0.4% (inside the continuity bound).
        uint256 buf = vault.buffer();
        vm.prank(keeper);
        vault.sendToDerive(buf);
        uint256 navDerive = 100e18 + a + b;
        int256 move = int256(uint256(bound(gainBps, 0, 80))) - 40; // −40..+40 bps
        navDerive = uint256(int256(navDerive) + int256(navDerive) * move / 10_000);

        // Round 2: alice redeems a fraction.
        uint256 redeemShares = sa * bound(uint256(redeemBps), 1, 10_000) / 10_000;
        if (redeemShares < vault.minRedeem()) redeemShares = vault.minRedeem() > sa ? sa : vault.minRedeem();
        vm.prank(alice);
        vault.requestRedeem(redeemShares, alice, alice);
        vm.warp(FRIDAY_0800 + WEEK + 10 minutes);
        vault.processRound(_submit(_flat(navDerive)));
        DeltaVault.Round memory r2 = vault.rounds(2);

        // Remaining holders keep the post-fee price: NAV after flows over supply equals the round's pps.
        uint256 ppsAfter = vault.lastNavPost() * 1e18 / vault.totalSupply();
        // Rounding always favors the vault: never below the round price, and only by dust above it.
        assertGe(ppsAfter, r2.pps, "redemption diluted remaining holders");
        assertApproxEqRel(ppsAfter, r2.pps, 1e3, "more than rounding dust");
        assertEq(vault.reserveUnfunded(), r2.assetsOwed, "owed must be fully reserved");
        assertEq(vault.claimableRedeemRequest(2, alice), redeemShares);
    }
}
