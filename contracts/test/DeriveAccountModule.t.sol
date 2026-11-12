// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {BaseTest} from "./Base.t.sol";
import {DeriveAccountModule} from "../src/DeriveAccountModule.sol";

contract DeriveAccountModuleTest is BaseTest {
    address internal hedgeKey = makeAddr("hedgeKey");

    function setUp() public override {
        super.setUp();
        _seed(1e18);
    }

    function _scopes(uint256 a) internal pure returns (uint256[] memory s) {
        s = new uint256[](1);
        s[0] = a;
    }

    function test_grantKey_encodesSessionKeyBoundToSubaccount() public {
        uint64 expiry = uint64(block.timestamp + 30 days);
        vm.prank(governance);
        module.grantKey(hedgeKey, _scopes(5), expiry);

        assertEq(actionManager.lastActionType(), 51);
        (address key, uint256 exp, uint256[] memory scopes, uint256[] memory subaccounts) =
            abi.decode(actionManager.lastActionData(), (address, uint256, uint256[], uint256[]));
        assertEq(key, hedgeKey);
        assertEq(exp, expiry);
        assertEq(scopes[0], 5);
        assertEq(subaccounts.length, 1);
        assertEq(subaccounts[0], SUBACCOUNT);
    }

    function test_grantKey_rejectsWithdrawTransferAdminScopes() public {
        uint256[3] memory forbidden = [uint256(0), 1, 11]; // admin, withdraw, transfer:all
        for (uint256 i; i < 3; ++i) {
            vm.prank(governance);
            vm.expectRevert(abi.encodeWithSelector(DeriveAccountModule.ScopeNotAllowed.selector, forbidden[i]));
            module.grantKey(hedgeKey, _scopes(forbidden[i]), uint64(block.timestamp + 1 days));
        }
    }

    function test_grantKey_onlyGovernance_andLifetimeCapped() public {
        vm.prank(guardian);
        vm.expectRevert(DeriveAccountModule.NotAuthorized.selector);
        module.grantKey(hedgeKey, _scopes(5), uint64(block.timestamp + 1 days));

        vm.prank(governance);
        vm.expectRevert(DeriveAccountModule.KeyLifetimeTooLong.selector);
        module.grantKey(hedgeKey, _scopes(5), uint64(block.timestamp + 31 days));
    }

    function test_renew_byKeeper_keepsScopes() public {
        vm.startPrank(governance);
        module.grantKey(hedgeKey, _scopes(5), uint64(block.timestamp + 1 days));
        module.setKeeper(keeper, true);
        vm.stopPrank();

        vm.warp(block.timestamp + 20 days);
        vm.prank(keeper);
        module.renewKey(hedgeKey, uint64(block.timestamp + 30 days));
        (bool approved, uint64 expiry, uint256[] memory scopes) = module.keyGrant(hedgeKey);
        assertTrue(approved);
        assertEq(expiry, block.timestamp + 30 days);
        assertEq(scopes[0], 5);
    }

    function test_revoke_byGuardian_sendsZeroExpiry() public {
        vm.prank(governance);
        module.grantKey(hedgeKey, _scopes(6), uint64(block.timestamp + 1 days));
        vm.prank(guardian);
        module.revokeKey(hedgeKey);
        (address key, uint256 exp,,) =
            abi.decode(actionManager.lastActionData(), (address, uint256, uint256[], uint256[]));
        assertEq(key, hedgeKey);
        assertEq(exp, 0);
        (bool approved,,) = module.keyGrant(hedgeKey);
        assertFalse(approved);
    }

    function test_fundsMoveOnlyThroughVault() public {
        vm.prank(keeper);
        vm.expectRevert(DeriveAccountModule.NotAuthorized.selector);
        module.withdrawToVault(1e18, 0, false);
        vm.prank(alice);
        vm.expectRevert(DeriveAccountModule.NotAuthorized.selector);
        module.depositToDerive(1e18);
    }

    function test_setupLocksAfterCompletion() public {
        vm.prank(admin);
        vm.expectRevert(DeriveAccountModule.NotAuthorized.selector);
        module.setSubaccountId(99);
    }
}
