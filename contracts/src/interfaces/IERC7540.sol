// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

/// @notice ERC-7540 asynchronous deposit and redeem, plus the operator model.
interface IERC7540 {
    event DepositRequest(
        address indexed controller, address indexed owner, uint256 indexed requestId, address sender, uint256 assets
    );
    event RedeemRequest(
        address indexed controller, address indexed owner, uint256 indexed requestId, address sender, uint256 shares
    );
    event OperatorSet(address indexed controller, address indexed operator, bool approved);

    function requestDeposit(uint256 assets, address controller, address owner) external returns (uint256 requestId);
    function pendingDepositRequest(uint256 requestId, address controller) external view returns (uint256 assets);
    function claimableDepositRequest(uint256 requestId, address controller) external view returns (uint256 assets);

    function requestRedeem(uint256 shares, address controller, address owner) external returns (uint256 requestId);
    function pendingRedeemRequest(uint256 requestId, address controller) external view returns (uint256 shares);
    function claimableRedeemRequest(uint256 requestId, address controller) external view returns (uint256 shares);

    function setOperator(address operator, bool approved) external returns (bool);
    function isOperator(address controller, address operator) external view returns (bool);

    function deposit(uint256 assets, address receiver, address controller) external returns (uint256 shares);
    function mint(uint256 shares, address receiver, address controller) external returns (uint256 assets);
}
