// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

/// @title PolicyRegistry
/// @notice Commits the hash of the off-chain strategy policy (spec 05 §3.6). Signers and the monitor refuse to act
///         under any policy whose hash isn't `activeHash`. Only governance (the timelock) can change it.
contract PolicyRegistry {
    address public immutable governance;

    bytes32 public activeHash;
    string public activeUri;
    uint64 public activatedAt;

    event PolicyActivated(bytes32 indexed hash, string uri);

    error NotAuthorized();

    constructor(address governance_, bytes32 initialHash, string memory initialUri) {
        governance = governance_;
        _activate(initialHash, initialUri);
    }

    function activate(bytes32 hash, string calldata uri) external {
        if (msg.sender != governance) revert NotAuthorized();
        _activate(hash, uri);
    }

    function _activate(bytes32 hash, string memory uri) internal {
        activeHash = hash;
        activeUri = uri;
        activatedAt = uint64(block.timestamp);
        emit PolicyActivated(hash, uri);
    }
}
