# Next session — where to pick up

**File to draft:** `skill/references/input-proofs.md`

**Process:** middle-path heavy. Mode: batch (decided at end of last session — input-proof patterns are self-contained, don't layer like ACL patterns might).

**Why heavy-mode:** the failure modes here (proof binding, sender mismatch, contract-address mismatch, replay scope) are exactly the class where a tired draft produces plausible-but-wrong code. The euint256 matrix and euint160 workaround are the warnings — same risk profile.

## Opening move

Run these three greps and paste the output as the first message — evidence base for the draft:

```bash
cd ~/zama-bounty/learning
grep -nE "function fromExternal|function createEncryptedInput" node_modules/@fhevm/solidity/lib/FHE.sol
grep -rn "createEncryptedInput\|fromExternal" node_modules/@fhevm/hardhat-plugin/_types/ 2>/dev/null | head -20
grep -nE "externalE(uint|bool|address)" node_modules/@fhevm/solidity/lib/FHE.sol | head -10
```

Three greps: on-chain conversion (`fromExternal`), test-side input creation (`createEncryptedInput` in the plugin), confirmation of external type variants. Together they map the input-proof surface from frontend-encryption-and-proof-generation through on-chain-verification-and-conversion.

## Skim before greping

Pre-load intuition by re-reading the existing working code:

- `learning/contracts/ConfidentialCounter.sol` — `increment(externalEuint32, bytes)` + `FHE.fromExternal(...)` pattern.
- `learning/contracts/ConfidentialVote.sol` — same shape, multiple call sites.
- `learning/test/ConfidentialCounter.ts` — `fhevm.createEncryptedInput(contractAddress, signer.address).add32(value).encrypt()` and how the result feeds into the contract call.
- `learning/test/ConfidentialVote.ts` — same plus multiple voter signers.

The `(contractAddress, signer.address)` pair in `createEncryptedInput` is the proof binding — that's the load-bearing detail. Re-reading the working code refreshes why those two specific arguments matter before drafting the rules around what happens when they mismatch.

## Structural note for the draft

`input-proofs.md` lives at the boundary between the frontend (proof generation via relayer SDK or hardhat-plugin mock) and the contract (proof verification via `FHE.fromExternal`). Both halves matter. The file should cover:

1. The on-chain side — `externalE*` types, `FHE.fromExternal(handle, proof)`, what's verified, what reverts.
2. The frontend / test side — `fhevm.createEncryptedInput`, the relayer SDK equivalent for production.
3. The proof binding rules — `(contract, sender)` binding, what happens when either mismatches, replay scope.
4. Anti-patterns specific to input proofs (likely small set; refer out to `anti-patterns.md` for stale-API ones).

Cross-ref `access-control.md` §1.3 on the auto-grant behavior of `fromExternal` (transient ACL on the contract) — that's a load-bearing fact that lives in this file's domain even though §1.3 already mentions it.

## State of play

- 5 reference files complete: `core-rules`, `anti-patterns`, `encrypted-types`, `operations`, `access-control`.
- 6 artifacts remaining: 2 heavy references (`input-proofs`, `decryption`), 3 lighter (`frontend-integration`, `testing`, `troubleshooting`), 2 templates (`Contract.sol`, `Contract.test.ts`), 1 script (`lint-antipatterns.js`).
- April 19, 21 days to May 10 deadline. Comfortable.

Delete this file when `input-proofs.md` ships.
