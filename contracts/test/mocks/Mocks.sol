// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IOnchainActionManager} from "../../src/interfaces/IOnchainActionManager.sol";
import {IChainlinkAggregator} from "../../src/interfaces/IChainlinkAggregator.sol";

contract MockToken is ERC20 {
    uint8 internal immutable _dec;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _dec = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Stand-in for Derive's OnchainActionManager: holds deposited tokens and records every action.
contract MockActionManager is IOnchainActionManager {
    IERC20 public immutable token;
    uint256 public constant WITHDRAWAL_FEE = 0.002 ether;

    uint256 public actionCount;
    uint64 public lastActionType;
    bytes public lastActionData;
    address public lastSender;
    WithdrawalParams public lastWithdrawal;

    constructor(IERC20 token_) {
        token = token_;
    }

    function submit(uint64 actionType, bytes calldata data) external returns (uint256) {
        lastActionType = actionType;
        lastActionData = data;
        lastSender = msg.sender;
        return ++actionCount;
    }

    function deposit(address, uint256 amount, uint64, address) external returns (uint256) {
        token.transferFrom(msg.sender, address(this), amount);
        lastActionType = 1;
        lastSender = msg.sender;
        return ++actionCount;
    }

    function depositToNewSubaccount(address, uint256 amount, uint32, address) external returns (uint256) {
        token.transferFrom(msg.sender, address(this), amount);
        lastActionType = 2;
        lastSender = msg.sender;
        return ++actionCount;
    }

    function withdraw(WithdrawalParams calldata params) external payable returns (uint256) {
        require(msg.value == WITHDRAWAL_FEE, "fee");
        lastWithdrawal = params;
        lastActionType = 3;
        lastSender = msg.sender;
        return ++actionCount;
    }

    /// @notice Test hook: pays out a withdrawal as Derive's outbox would after the batch is proven.
    function payOut(address recipient, uint256 amount) external {
        token.transfer(recipient, amount);
    }
}

contract MockChainlink is IChainlinkAggregator {
    int256 public answer;
    uint256 public updatedAt;

    function set(int256 answer_, uint256 updatedAt_) external {
        answer = answer_;
        updatedAt = updatedAt_;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}
