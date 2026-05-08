// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Template — minimal correct skeleton for an FHEVM contract.
// Targets @fhevm/solidity ≥0.10 with evmVersion: "cancun".
// References this skill's documentation by path; replace MyContract and the
// example state and function with your actual contract logic.

import {FHE, euint32, externalEuint32} from "@fhevm/solidity/lib/FHE.sol";
import {ZamaEthereumConfig} from "@fhevm/solidity/config/ZamaConfig.sol";

// ZamaEthereumConfig is the canonical config for Ethereum-side networks
// (Sepolia, mainnet) — it resolves coprocessor addresses by block.chainid,
// no per-network variant needed. Do not import the legacy SepoliaConfig
// (without the Zama prefix) — it was removed in v0.10. See
// references/anti-patterns.md §1.3 for the trap.

contract MyContract is ZamaEthereumConfig {
    // Encrypted state. Choose the smallest type that fits your range —
    // see references/encrypted-types.md §1 for the decision table.
    euint32 private _state;

    constructor() {
        _state = FHE.asEuint32(0);
        FHE.allowThis(_state);
        // ACL on _state:
        //   contract: uses in subsequent ops
        //   everyone else: cannot read until you add explicit FHE.allow grants
    }

    // Example mutating function — takes an encrypted input, validates the
    // proof, updates state, re-grants ACL on the new handle.
    function exampleMutate(externalEuint32 enc, bytes calldata proof) external {
        // FHE.fromExternal verifies the proof binds to (this contract, msg.sender).
        // See references/input-proofs.md §2 for the dual-path verification surface.
        euint32 input = FHE.fromExternal(enc, proof);

        // TODO: Replace this with your contract's actual logic.
        //   - Validate inputs (ranges, conditions — using FHE comparison ops)
        //   - Compute new state via FHE operations (see references/operations.md)
        //   - Update _state and call FHE.allowThis(_state) below
        //   - Add FHE.allow grants for external readers (see references/access-control.md §1.2)
        _state = FHE.add(_state, input);

        // CR-1: every FHE op produces a new handle with zero ACL. Re-grant.
        FHE.allowThis(_state);
        // Add FHE.allow(_state, addr) calls here for any external addresses
        // that should decrypt this handle off-chain. See
        // references/access-control.md §1.2 for the decision tree, and §4.2
        // for the per-voter / aggregate leak that makes the second-grant
        // choice subtle.
        // ACL on _state:
        //   contract: uses in subsequent ops
        //   everyone else: cannot read until you add explicit FHE.allow grants
    }
}
