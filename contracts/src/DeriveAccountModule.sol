// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IOnchainActionManager} from "./interfaces/IOnchainActionManager.sol";

/// @title DeriveAccountModule
/// @notice Owns the vault's Derive v3 account. It deposits, grants/renews/revokes session keys and withdraws, all as
///         L1 calls to Derive's `OnchainActionManager`. Withdrawals always pay `vault`.
/// @dev Immutable on purpose: Derive has no way to transfer account ownership (spec 05 §6).
contract DeriveAccountModule is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint64 public constant SET_SESSION_KEY = 51;
    uint256 public constant MAX_KEY_LIFETIME = 30 days;

    // Derive protocol scope codes this module may grant (spec 05 §2).
    uint256 public constant SCOPE_TRADE_ORDERBOOK_SPOT = 4;
    uint256 public constant SCOPE_TRADE_ORDERBOOK_PERP = 5;
    uint256 public constant SCOPE_TRADE_ORDERBOOK_OPTION = 6;
    uint256 public constant SCOPE_TRADE_RFQ_OPTION = 10;

    IOnchainActionManager public immutable actionManager;
    IERC20 public immutable token;
    /// @notice Derive's protocol asset label for `token` (deposit and withdraw take the label, not the ERC-20).
    address public immutable protocolAsset;
    uint32 public immutable managerId;
    address public immutable vault;
    address public immutable governance;
    address public immutable guardian;

    uint64 public subaccountId;
    bool public setupCompleted;
    address public setupAdmin;

    /// @notice Cumulative amounts, indexed by a per-module nonce, so the NAV oracle can tell what is still in transit.
    uint64 public depositNonce;
    uint64 public withdrawalNonce;
    mapping(uint64 => uint256) public cumulativeDeposited;
    mapping(uint64 => uint256) public cumulativeWithdrawn;

    struct KeyGrant {
        bool approved;
        uint64 expiry;
        uint256[] scopes;
    }

    mapping(address => KeyGrant) internal _keys;
    mapping(address => bool) public isKeeper;

    event SubaccountCreated(uint256 actionId, uint256 amount);
    event SubaccountIdSet(uint64 subaccountId);
    event SetupCompleted();
    event DepositedToDerive(uint64 indexed nonce, uint256 amount, uint256 actionId);
    event WithdrawalRequested(uint64 indexed nonce, uint256 amount, bool forceBatch, uint256 actionId);
    event SessionKeySet(address indexed key, uint256[] scopes, uint64 expiry);
    event SessionKeyRevoked(address indexed key);
    event KeeperSet(address indexed keeper, bool allowed);

    error NotAuthorized();
    error SetupAlreadyCompleted();
    error SubaccountNotSet();
    error SubaccountAlreadySet();
    error ScopeNotAllowed(uint256 scope);
    error KeyLifetimeTooLong();
    error KeyNotApproved();
    error ZeroAmount();
    error AmountTooLarge();
    error InsufficientFeeFloat();

    modifier onlyVault() {
        if (msg.sender != vault) revert NotAuthorized();
        _;
    }

    modifier onlyGovernance() {
        if (msg.sender != governance) revert NotAuthorized();
        _;
    }

    constructor(
        IOnchainActionManager actionManager_,
        IERC20 token_,
        address protocolAsset_,
        uint32 managerId_,
        address vault_,
        address governance_,
        address guardian_,
        address setupAdmin_
    ) {
        actionManager = actionManager_;
        token = token_;
        protocolAsset = protocolAsset_;
        managerId = managerId_;
        vault = vault_;
        governance = governance_;
        guardian = guardian_;
        setupAdmin = setupAdmin_;
    }

    receive() external payable {}

    // ---------------------------------------------------------------------------------------------------------------
    // Setup (one-time, before `setupCompleted`)
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Creates the Derive subaccount with the vault's seed deposit (already transferred here by the vault).
    function createSubaccount(uint256 amount) external onlyVault nonReentrant returns (uint64 nonce) {
        if (setupCompleted || subaccountId != 0 || depositNonce != 0) revert SubaccountAlreadySet();
        if (amount == 0) revert ZeroAmount();
        token.forceApprove(address(actionManager), amount);
        uint256 actionId = actionManager.depositToNewSubaccount(protocolAsset, amount, managerId, address(this));
        nonce = ++depositNonce;
        cumulativeDeposited[nonce] = amount;
        emit SubaccountCreated(actionId, amount);
        emit DepositedToDerive(nonce, amount, actionId);
    }

    /// @notice Records the subaccount id Derive assigned. The id is only known after the sequencer applies the deposit.
    function setSubaccountId(uint64 id) external {
        if (msg.sender != setupAdmin || setupCompleted) revert NotAuthorized();
        if (id == 0) revert SubaccountNotSet();
        subaccountId = id;
        emit SubaccountIdSet(id);
    }

    function completeSetup() external {
        if (msg.sender != setupAdmin || setupCompleted) revert NotAuthorized();
        if (subaccountId == 0) revert SubaccountNotSet();
        setupCompleted = true;
        setupAdmin = address(0);
        emit SetupCompleted();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Funds
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Sends `amount` of `token` (already transferred here by the vault) into the Derive subaccount.
    function depositToDerive(uint256 amount) external onlyVault nonReentrant returns (uint64 nonce) {
        if (amount == 0) revert ZeroAmount();
        if (subaccountId == 0) revert SubaccountNotSet();
        token.forceApprove(address(actionManager), amount);
        uint256 actionId = actionManager.deposit(protocolAsset, amount, subaccountId, address(this));
        nonce = ++depositNonce;
        cumulativeDeposited[nonce] = cumulativeDeposited[nonce - 1] + amount;
        emit DepositedToDerive(nonce, amount, actionId);
    }

    /// @notice Queues an owner withdrawal from Derive, always paid to `vault`. The vault enforces the amount cap.
    function withdrawToVault(uint256 amount, uint128 maxFeeUsdE18, bool forceBatch)
        external
        onlyVault
        nonReentrant
        returns (uint64 nonce)
    {
        if (amount == 0) revert ZeroAmount();
        if (amount > type(uint128).max) revert AmountTooLarge();
        if (subaccountId == 0) revert SubaccountNotSet();
        uint256 fee = actionManager.WITHDRAWAL_FEE();
        if (address(this).balance < fee) revert InsufficientFeeFloat();
        uint256 actionId = actionManager.withdraw{value: fee}(
            IOnchainActionManager.WithdrawalParams({
                subaccountId: subaccountId,
                protocolAsset: protocolAsset,
                maxFeeUsdE18: maxFeeUsdE18,
                recipient: vault,
                amountInUnderlying: uint128(amount),
                forceBatch: forceBatch
            })
        );
        nonce = ++withdrawalNonce;
        cumulativeWithdrawn[nonce] = cumulativeWithdrawn[nonce - 1] + amount;
        emit WithdrawalRequested(nonce, amount, forceBatch, actionId);
    }

    /// @notice Assets sent to Derive whose credit the given report has not seen yet.
    function depositsInTransit(uint64 lastCreditedNonce) external view returns (uint256) {
        if (lastCreditedNonce > depositNonce) lastCreditedNonce = depositNonce;
        return cumulativeDeposited[depositNonce] - cumulativeDeposited[lastCreditedNonce];
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Session keys
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Approves and registers a session key. New keys or scopes always come through governance (the timelock).
    function grantKey(address key, uint256[] calldata scopes, uint64 expiry) external onlyGovernance {
        for (uint256 i; i < scopes.length; ++i) {
            if (!_scopeAllowed(scopes[i])) revert ScopeNotAllowed(scopes[i]);
        }
        _keys[key] = KeyGrant({approved: true, expiry: 0, scopes: scopes});
        _setKey(key, expiry);
    }

    /// @notice Extends an approved key with the same scopes. Adds no power, so the keeper may do it without delay.
    function renewKey(address key, uint64 expiry) external {
        if (!isKeeper[msg.sender] && msg.sender != governance) revert NotAuthorized();
        if (!_keys[key].approved) revert KeyNotApproved();
        _setKey(key, expiry);
    }

    /// @notice Revokes a key on Derive and forgets its approval. Guardian or governance, effective from L1 immediately.
    function revokeKey(address key) external {
        if (msg.sender != guardian && msg.sender != governance) revert NotAuthorized();
        if (subaccountId == 0) revert SubaccountNotSet();
        delete _keys[key];
        actionManager.submit(SET_SESSION_KEY, abi.encode(key, uint256(0), new uint256[](0), new uint256[](0)));
        emit SessionKeyRevoked(key);
    }

    function setKeeper(address keeper, bool allowed) external {
        // Adding a keeper adds power (governance only); removing one is risk-reducing (guardian may do it too).
        if (allowed ? msg.sender != governance : (msg.sender != governance && msg.sender != guardian)) {
            revert NotAuthorized();
        }
        isKeeper[keeper] = allowed;
        emit KeeperSet(keeper, allowed);
    }

    function keyGrant(address key) external view returns (bool approved, uint64 expiry, uint256[] memory scopes) {
        KeyGrant storage g = _keys[key];
        return (g.approved, g.expiry, g.scopes);
    }

    function _setKey(address key, uint64 expiry) internal {
        if (subaccountId == 0) revert SubaccountNotSet();
        if (expiry > block.timestamp + MAX_KEY_LIFETIME) revert KeyLifetimeTooLong();
        KeyGrant storage g = _keys[key];
        g.expiry = expiry;
        uint256[] memory subaccounts = new uint256[](1);
        subaccounts[0] = subaccountId;
        actionManager.submit(SET_SESSION_KEY, abi.encode(key, uint256(expiry), g.scopes, subaccounts));
        emit SessionKeySet(key, g.scopes, expiry);
    }

    function _scopeAllowed(uint256 scope) internal pure returns (bool) {
        return scope == SCOPE_TRADE_ORDERBOOK_SPOT || scope == SCOPE_TRADE_ORDERBOOK_PERP
            || scope == SCOPE_TRADE_ORDERBOOK_OPTION || scope == SCOPE_TRADE_RFQ_OPTION;
    }
}
