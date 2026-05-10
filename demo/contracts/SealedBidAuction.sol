// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FHE, euint32, externalEuint32, ebool} from "@fhevm/solidity/lib/FHE.sol";
import {ZamaEthereumConfig} from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title SealedBidAuction — confidential first-price sealed-bid auction
/// @notice Three pre-registered bidders submit encrypted bids before a deadline.
///         After the deadline, the admin computes the winning bid via encrypted
///         comparison (FHE.gt + FHE.select) and reveals only the winning amount
///         publicly. Individual losing bids stay encrypted forever.
///
/// Patterns demonstrated:
///   - Per-bidder storage with per-bidder ACL (each bidder can decrypt their
///     own bid; aggregate winning amount is revealed only via public-decrypt
///     after the deadline). See access-control.md §4 in the skill.
///   - Encrypted comparison via FHE.gt returning ebool, fed into FHE.select
///     to compute the running max without leaking ordering. See operations.md
///     §2.4 in the skill.
///   - Deadline-gated public decryption — FHE.makePubliclyDecryptable only
///     called after block.timestamp >= deadline. See decryption.md §2 in the skill.
contract SealedBidAuction is ZamaEthereumConfig {
    address public admin;
    uint256 public deadline;
    address[3] public bidders;

    /// @notice Each bidder's encrypted bid. Bidder reads their own only.
    mapping(address => euint32) public bids;

    /// @notice The winning bid amount, computed at reveal time.
    euint32 private _winningBid;

    bool public revealed;

    event Revealed(bytes32 winningBidHandle);

    constructor(uint256 _deadline, address[3] memory _bidders) {
        admin = msg.sender;
        deadline = _deadline;
        bidders = _bidders;

        _winningBid = FHE.asEuint32(0);
        FHE.allowThis(_winningBid);

        // Pre-initialize each bidder's slot to encrypted zero, granted to the bidder.
        // This way, bidders who never call submitBid still have a well-defined slot
        // (encrypted zero), and reveal() can iterate without an isInitialized check.
        for (uint256 i = 0; i < 3; i++) {
            bids[_bidders[i]] = FHE.asEuint32(0);
            FHE.allowThis(bids[_bidders[i]]);
            FHE.allow(bids[_bidders[i]], _bidders[i]);
        }
    }

    /// @notice Submit an encrypted bid. Caller must be a registered bidder.
    function submitBid(externalEuint32 encBid, bytes calldata inputProof) external {
        require(block.timestamp < deadline, "auction closed");
        require(_isBidder(msg.sender), "not a registered bidder");
        require(!revealed, "already revealed");

        euint32 amount = FHE.fromExternal(encBid, inputProof);
        bids[msg.sender] = amount;

        // ACL on bids[msg.sender]:
        //   contract: uses in subsequent ops (reveal computes the max over these)
        //   msg.sender: decrypts their own bid off-chain
        //   everyone else (including other bidders, admin): cannot read this bidder's amount
        FHE.allowThis(bids[msg.sender]);
        FHE.allow(bids[msg.sender], msg.sender);
    }

    /// @notice Compute the winning bid via encrypted comparison and reveal it publicly.
    function reveal() external {
        require(msg.sender == admin, "not admin");
        require(block.timestamp >= deadline, "too early");
        require(!revealed, "already revealed");

        // Iterate over bidders, building the max via FHE.gt + FHE.select.
        // Both branches always compute (Solidity is eager); the select is a
        // ciphertext mux, so which branch "wins" does not leak through gas.
        for (uint256 i = 0; i < 3; i++) {
            ebool isHigher = FHE.gt(bids[bidders[i]], _winningBid);
            _winningBid = FHE.select(isHigher, bids[bidders[i]], _winningBid);
            FHE.allowThis(_winningBid);
        }

        FHE.makePubliclyDecryptable(_winningBid);
        revealed = true;

        emit Revealed(euint32.unwrap(_winningBid));
    }

    /// @notice Returns the winning bid handle once reveal() has been called.
    ///         Off-chain code calls fhevm.publicDecryptEuint or relayer-SDK
    ///         publicDecrypt to read the plaintext.
    function getWinningBid() external view returns (euint32) {
        require(revealed, "not yet revealed");
        return _winningBid;
    }

    function _isBidder(address addr) internal view returns (bool) {
        return addr == bidders[0] || addr == bidders[1] || addr == bidders[2];
    }
}
