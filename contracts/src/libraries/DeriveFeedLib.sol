// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @title DeriveFeedLib
/// @notice Verifies Derive's oracle-signed feeds on L1 (spec 02 §3.1). Derive v3 signs feeds with an EIP-712 scheme
///         whose domain still names the retired Derive Chain (chain id 957) and the v2 feed contracts, so the domain
///         separator is passed in as a constant rather than derived from `block.chainid`.
library DeriveFeedLib {
    bytes32 internal constant FEED_DATA_TYPEHASH = keccak256("FeedData(bytes data,uint256 deadline,uint64 timestamp)");
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    struct FeedData {
        bytes data;
        uint256 deadline;
        uint64 timestamp;
        address[] signers;
        bytes[] signatures;
    }

    error NotEnoughFeedSigners();
    error FeedSignersMismatch();
    error DuplicateFeedSigner();
    error InvalidFeedSigner(address signer);
    error InvalidFeedSignature(address signer);
    error FeedExpired();
    error FeedFromFuture();
    error FeedTooFarFromReport();
    error FeedPriceZero();

    function domainSeparator(string memory name, string memory version, uint256 chainId, address verifyingContract)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256(bytes(name)), keccak256(bytes(version)), chainId, verifyingContract)
        );
    }

    function hashFeedData(FeedData memory f) internal pure returns (bytes32) {
        return keccak256(abi.encode(FEED_DATA_TYPEHASH, keccak256(f.data), f.deadline, f.timestamp));
    }

    /// @notice Decodes and verifies a signed spot feed, returning the 18-decimal USD spot price.
    /// @param encoded abi.encode(FeedData) as published by `public/get_latest_signed_feeds`.
    /// @param anchor the report timestamp the feed must be close to.
    function verifySpot(
        bytes calldata encoded,
        bytes32 domain,
        mapping(address => bool) storage isSigner,
        uint8 required,
        uint64 anchor,
        uint64 maxDistance
    ) internal view returns (uint256 price) {
        FeedData memory f = abi.decode(encoded, (FeedData));
        _verify(f, domain, isSigner, required);
        uint256 distance = f.timestamp > anchor ? f.timestamp - anchor : anchor - f.timestamp;
        if (distance > maxDistance) revert FeedTooFarFromReport();
        (uint96 spot,) = abi.decode(f.data, (uint96, uint64));
        if (spot == 0) revert FeedPriceZero();
        return spot;
    }

    function _verify(FeedData memory f, bytes32 domain, mapping(address => bool) storage isSigner, uint8 required)
        private
        view
    {
        uint256 n = f.signers.length;
        if (n < required) revert NotEnoughFeedSigners();
        if (n != f.signatures.length) revert FeedSignersMismatch();
        bytes32 digest = MessageHashUtils.toTypedDataHash(domain, hashFeedData(f));
        for (uint256 i; i < n; ++i) {
            address signer = f.signers[i];
            for (uint256 j; j < i; ++j) {
                if (f.signers[j] == signer) revert DuplicateFeedSigner();
            }
            if (!isSigner[signer]) revert InvalidFeedSigner(signer);
            (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, f.signatures[i]);
            if (err != ECDSA.RecoverError.NoError || recovered != signer) revert InvalidFeedSignature(signer);
        }
        if (f.deadline < block.timestamp) revert FeedExpired();
        if (f.timestamp > block.timestamp) revert FeedFromFuture();
    }
}
