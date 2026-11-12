// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

/// @notice The subset of Derive v3's L1 `OnchainActionManager` the vault uses.
/// @dev Mainnet proxy 0xE366CcA474968e33b777E13905829A3b800CFAD3. Action ids 1–3 are fixed;
///      `submit` accepts public ids 51–9999 (51 = SetSessionKey).
interface IOnchainActionManager {
    struct WithdrawalParams {
        uint64 subaccountId;
        address protocolAsset; // protocol asset label, not the ERC-20
        uint128 maxFeeUsdE18; // multiple of 1e6
        address recipient;
        uint128 amountInUnderlying; // native ERC-20 decimals
        bool forceBatch;
    }

    function WITHDRAWAL_FEE() external view returns (uint256);

    function submit(uint64 actionType, bytes calldata data) external returns (uint256 actionId);

    function deposit(address asset, uint256 amount, uint64 subaccountId, address fallbackRecipient)
        external
        returns (uint256 actionId);

    function depositToNewSubaccount(address asset, uint256 amount, uint32 managerId, address owner_)
        external
        returns (uint256 actionId);

    function withdraw(WithdrawalParams calldata params) external payable returns (uint256 actionId);
}
