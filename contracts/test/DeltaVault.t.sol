// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BaseTest} from "./Base.t.sol";
import {DeltaVault} from "../src/DeltaVault.sol";
import {NavOracle} from "../src/NavOracle.sol";
import {DeriveAccountModule} from "../src/DeriveAccountModule.sol";
import {IOnchainActionManager} from "../src/interfaces/IOnchainActionManager.sol";

contract DeltaVaultTest is BaseTest {
    function setUp() public override {
        super.setUp();
        _seed(1e18);
    }

    function test_seed_mintsDeadSharesAndOpensFirstRound() public view {
        assertEq(vault.totalSupply(), 1e18);
        assertEq(vault.balanceOf(0x000000000000000000000000000000000000dEaD), 1e18);
        assertEq(vault.openRound(), 1);
        assertEq(vault.rounds(1).cutoff, FRIDAY_0800);
        assertEq(module.depositNonce(), 1);
        assertEq(weth.balanceOf(address(actionManager)), 1e18);
    }

    function test_weeklyRound_depositIsPricedAfterCutoffAndClaimable() public {
        uint256 id = _requestDeposit(alice, 10e18);
        assertEq(id, 1);
        assertEq(vault.pendingDepositRequest(1, alice), 10e18);

        vm.warp(FRIDAY_0800 + 15 minutes);
        uint64 rid = _submit(_flat(1e18)); // seed credited on Derive; no options open
        vault.processRound(rid);

        DeltaVault.Round memory r = vault.rounds(1);
        assertGt(r.pps, 0);
        assertEq(vault.lastProcessed(), 1);
        assertEq(vault.rounds(2).cutoff, FRIDAY_0800 + WEEK);

        uint256 claimable = vault.maxMint(alice);
        assertApproxEqRel(claimable, 10e18 * 1e18 / r.depositPrice, 1e-12 * 1e18);
        vm.prank(alice);
        uint256 shares = vault.deposit(10e18, alice, alice);
        assertEq(vault.balanceOf(alice), shares);
        assertEq(vault.buffer(), 10e18);
        assertEq(vault.idlePending(), 0);
    }

    function test_processRound_beforeCutoffReverts() public {
        _requestDeposit(alice, 1e18);
        vm.warp(FRIDAY_0800 - 1);
        uint64 rid = _submit(_flat(1e18));
        vm.expectRevert(DeltaVault.NoClosedRound.selector);
        vault.processRound(rid);
    }

    function test_processRound_reportBeforeCutoffReverts() public {
        _requestDeposit(alice, 1e18);
        vm.warp(FRIDAY_0800 - 5 minutes);
        uint64 rid = _submit(_flat(1e18));
        vm.warp(FRIDAY_0800 + 1);
        vm.expectRevert(DeltaVault.ReportBeforeCutoff.selector);
        vault.processRound(rid);
    }

    function test_processRound_requiresFlatOptionsInPhase1() public {
        _requestDeposit(alice, 1e18);
        vm.warp(FRIDAY_0800 + 10 minutes);
        Snapshot memory s = _flat(1e18);
        s.optionCount = 1;
        s.optionsValue = -1e18;
        s.cash = 1e18;
        uint64 rid = _submit(s);
        vm.expectRevert(DeltaVault.OptionsOpen.selector);
        vault.processRound(rid);
    }

    function test_processRound_mustUseLatestReport() public {
        _requestDeposit(alice, 1e18);
        vm.warp(FRIDAY_0800 + 10 minutes);
        uint64 first = _submit(_flat(1e18));
        vm.warp(block.timestamp + 1 minutes);
        _submit(_flat(1e18));
        vm.expectRevert(DeltaVault.ReportNotLatest.selector);
        vault.processRound(first);
    }

    function test_requestsAfterCutoffJoinNextRound() public {
        _requestDeposit(alice, 1e18);
        vm.warp(FRIDAY_0800 + 1);
        uint256 id = _requestDeposit(bob, 2e18);
        assertEq(id, 2);
        uint64 rid = _submit(_flat(1e18));
        vault.processRound(rid);
        assertEq(vault.maxDeposit(alice), 1e18);
        assertEq(vault.maxDeposit(bob), 0);
        assertEq(vault.pendingDepositRequest(2, bob), 2e18);
    }

    function test_cancelDeposit_onlyWhileRoundOpen() public {
        _requestDeposit(alice, 3e18);
        vm.prank(alice);
        vault.cancelDepositRequest(1, alice, alice);
        assertEq(weth.balanceOf(alice), 3e18);
        assertEq(vault.idlePending(), 0);

        _requestDeposit(alice, 1e18);
        vm.warp(FRIDAY_0800);
        vm.prank(alice);
        vm.expectRevert(DeltaVault.NotOpenRound.selector);
        vault.cancelDepositRequest(1, alice, alice);
    }

    /// @notice Reproduces spec 01 §10 (fees part): navPre 1001.2 WETH after one day on 1000 shares, 2%/15% fees.
    function test_fees_matchSpecExample() public {
        DeltaVault fresh = _freshDailyVault(1000e18);
        // One deposit so the round has flows and fees crystallize.
        weth.mint(alice, 50e18);
        vm.startPrank(alice);
        weth.approve(address(fresh), 50e18);
        fresh.requestDeposit(50e18, alice, alice);
        vm.stopPrank();

        uint64 cutoff = fresh.rounds(1).cutoff;
        vm.warp(cutoff);
        Snapshot memory s = _flat(1001.2e18);
        s.lastCreditedDeposit = 1;
        uint64 rid = _submit(s);
        fresh.processRound(rid);

        DeltaVault.Round memory r = fresh.rounds(1);
        assertApproxEqAbs(r.feeShares, 0.22641e18, 0.00001e18);
        assertApproxEqAbs(r.pps, 1.00097337e18, 0.00000001e18);
        assertEq(fresh.hwm(), r.pps);
        assertApproxEqAbs(fresh.balanceOf(feeCollector), r.feeShares, 0);
    }

    function test_redeemCycle_fundedFromDerive() public {
        // Round 1: alice deposits 10 WETH.
        _requestDeposit(alice, 10e18);
        vm.warp(FRIDAY_0800 + 10 minutes);
        vault.processRound(_submit(_flat(1e18)));
        vm.startPrank(alice);
        uint256 shares = vault.deposit(10e18, alice, alice);
        vm.stopPrank();

        // Keeper moves the deposit to Derive (phase 1: no buffer).
        vm.prank(keeper);
        vault.sendToDerive(10e18);
        assertEq(vault.buffer(), 0);

        // Round 2: alice redeems everything.
        vm.prank(alice);
        vault.requestRedeem(shares, alice, alice);
        vm.warp(FRIDAY_0800 + WEEK + 10 minutes);
        vault.processRound(_submit(_flat(11e18)));
        uint256 owed = vault.rounds(2).assetsOwed;
        assertGt(owed, 0);
        assertEq(vault.reserveUnfunded(), owed);
        assertEq(vault.maxWithdraw(alice), 0);

        // Keeper withdraws from Derive; the outbox pays the vault; anyone syncs.
        vm.prank(keeper);
        vault.requestDeriveWithdrawal(owed, false);
        (,,, address recipient, uint128 amount,) = actionManager.lastWithdrawal();
        assertEq(recipient, address(vault));
        assertEq(amount, owed);
        actionManager.payOut(address(vault), owed);
        vault.syncReceived();
        assertEq(vault.reserveUnfunded(), 0);
        assertEq(vault.reserveFunded(), owed);

        vm.prank(alice);
        vault.redeem(shares, alice, alice);
        assertEq(weth.balanceOf(alice), owed);
    }

    function test_withdrawalCap_limitsKeeper() public {
        vm.warp(FRIDAY_0800 + 10 minutes);
        vault.processRound(_submit(_flat(1e18)));
        vm.prank(keeper);
        vm.expectRevert(DeltaVault.ExceedsWithdrawalCap.selector);
        vault.requestDeriveWithdrawal(1, false);
    }

    function test_reduceOnly_refundsDepositsButProcessesRedemptions() public {
        _requestDeposit(alice, 5e18);
        vm.prank(guardian);
        vault.setReduceOnly();
        vm.warp(FRIDAY_0800 + 10 minutes);
        vault.processRound(_submit(_flat(1e18)));
        assertTrue(vault.rounds(1).depositsRefunded);
        assertEq(vault.claimableRefund(alice), 5e18);
        vm.prank(alice);
        vault.claimRefund(alice, alice);
        assertEq(weth.balanceOf(alice), 5e18);

        weth.mint(bob, 1e18);
        vm.startPrank(bob);
        weth.approve(address(vault), 1e18);
        vm.expectRevert(DeltaVault.DepositsDisabled.selector);
        vault.requestDeposit(1e18, bob, bob);
        vm.stopPrank();
    }

    function test_breaker_ignoresSmallDrawdown() public {
        vm.warp(FRIDAY_0800 - 2 hours);
        _submit(_flat(1e18));
        vault.checkpoint();
        vm.warp(block.timestamp + 1 hours);
        Snapshot memory s = _flat(0.96e18); // −4% in WETH while spot falls 5%
        s.spot = 1900e18;
        _submit(s);
        vm.expectRevert(DeltaVault.NoDrawdown.selector);
        vault.triggerBreaker();
    }

    function test_breaker_tripsOnDrawdownInVaultUnit() public {
        vm.warp(FRIDAY_0800 - 2 hours);
        _submit(_flat(1e18));
        vault.checkpoint();
        vm.warp(block.timestamp + 1 hours);
        Snapshot memory s = _flat(0.93e18); // −7% in WETH, spot −7%: passes continuity, trips the 6% breaker
        s.spot = 1860e18;
        _submit(s);
        vault.triggerBreaker();
        assertEq(uint8(vault.state()), uint8(DeltaVault.State.REDUCE_ONLY));
    }

    function test_upgrade_frozenFor180Days() public {
        address impl = address(new DeltaVault());
        vm.prank(governance);
        vm.expectRevert(DeltaVault.UpgradeFrozen.selector);
        vault.upgradeToAndCall(impl, "");
    }

    function _freshDailyVault(uint256 seedAssets) internal returns (DeltaVault fresh) {
        // Daily schedule (testnet-style), seeded exactly one day before its first cutoff.
        uint64 period = 1 days;
        uint64 offset = 8 hours;
        uint256 nextCut = offset + ((block.timestamp - offset) / period + 1) * period;
        vm.warp(nextCut - 1 days);

        fresh = DeltaVault(address(new ERC1967Proxy(address(new DeltaVault()), "")));
        fresh.initialize(_vaultArgs(DeltaVault.Schedule({period: period, offset: offset, requireFlatOptions: true})));
        module = new DeriveAccountModule(
            IOnchainActionManager(address(actionManager)),
            IERC20(address(weth)),
            address(weth),
            1,
            address(fresh),
            governance,
            guardian,
            admin
        );
        oracle = NavOracle(address(new ERC1967Proxy(address(new NavOracle()), "")));
        oracle.initialize(_oracleArgs());

        weth.mint(admin, seedAssets);
        vm.startPrank(admin);
        weth.approve(address(fresh), seedAssets);
        fresh.seed(oracle, module, seedAssets);
        module.setSubaccountId(SUBACCOUNT);
        module.completeSetup();
        vm.stopPrank();
    }
}
