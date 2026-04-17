---
name: zama-fhevm
description: Use when writing, testing, or deploying confidential Solidity smart contracts with Zama's FHEVM — any work involving encrypted on-chain state (euint, ebool, eaddress), fully homomorphic encryption on Ethereum, confidential tokens (ERC-7984, cUSDT), sealed-bid auctions, private voting, encrypted balances, Hardhat tests for FHEVM, Zama Protocol, the @fhevm/solidity or @fhevm/hardhat-plugin library, decryption handles, the @zama-fhe/relayer-sdk, or mock coprocessor errors. Trigger on phrases like "confidential smart contract," "encrypted state," "FHEVM," "Zama," "homomorphic," "private on-chain," "decrypt handle," "relayer SDK," or any import from @fhevm/solidity. Enforces per-handle ACL, blocks pre-v0.9 API patterns (requestDecryption, Gateway, SepoliaConfig), and serializes mock-coprocessor test operations.
---

# Zama FHEVM — Confidential Smart Contract Development

This skill targets `@fhevm/solidity ≥0.10` and `@fhevm/hardhat-plugin ≥0.4`.
If installed versions differ, run `scripts/verify-env.sh` and cross-check against `node_modules/@fhevm/solidity/lib/FHE.sol` before trusting any API name documented here.

---

## When to use this skill

Load this skill for any task matching:

- Writing Solidity contracts that store or operate on encrypted values (`euint*`, `ebool`, `eaddress`)
- Writing Hardhat tests for FHEVM contracts (the `@fhevm/hardhat-plugin` `fhevm` helper)
- Integrating a frontend with an FHEVM contract via `@zama-fhe/relayer-sdk`
- Debugging errors from `@fhevm/solidity`, `@fhevm/host-contracts`, or the FHEVM mock coprocessor
- Migrating contracts from FHEVM v0.7/v0.8 to v0.10+

Do **not** load this skill for: generic Solidity work, non-FHEVM privacy tech (ZK, Aztec, TEEs), or general EVM questions.

---

## Before writing any code — verification gate

Run the environment check. This is not optional.

```bash
bash scripts/verify-env.sh
```

The script confirms installed package versions and greps the installed library for every canonical symbol this skill relies on. If it exits non-zero, **stop**. Do not guess at API names. Report the failure to the user and ask whether to proceed against the installed (non-matching) versions or to update dependencies.

The reason this gate is blocking: FHEVM's API has changed substantially across versions (v0.7 → v0.8 → v0.10), and training data for most LLMs predates the current library. Running the verify script once at session start replaces trust-in-priors with trust-in-filesystem.

---

## Refused patterns — never generate these

The following patterns are either removed from the current library, incorrect in the current API, or reliably cause test flakes. Do not generate them. Refer to `references/anti-patterns.md` for full detail on each.

1. **`FHE.requestDecryption(...)` and any gateway-callback decryption flow.** Removed in v0.9. Use `FHE.makePubliclyDecryptable(handle)` + off-chain relayer decryption instead.
2. **`DecryptionOracle`, `GatewayCaller`, `onDecryptionResult(...)` callbacks.** All removed in v0.9 consolidation.
3. **`import {SepoliaConfig} from "@fhevm/solidity/config/ZamaConfig.sol"`.** Consolidated. Use `ZamaEthereumConfig` instead.
4. **`Promise.all([...fhevm.publicDecryptEuint(...), ...])` in tests.** Races the mock coprocessor's event cursor. Serialize with sequential `await`s instead.
5. **`if (encryptedBool)` or `require(encryptedBool)`.** Impossible — encrypted values cannot branch Solidity control flow. Use `FHE.select(cond, ifTrue, ifFalse)` for conditional values.
6. **Single `FHE.allowThis` in the constructor with no re-grants after operations.** Every FHE op produces a new handle with zero ACL. See CR-1 below.

If your generated code contains any of these, stop and revise before presenting to the user.

---

## Core rules — always follow, no exceptions

```
CR-1  Every FHE op produces a new handle with zero ACL; after every op,
      re-grant to every address that should read it (contract itself via
      FHE.allowThis, others via FHE.allow(handle, addr)).
CR-2  Before using any FHEVM symbol not already present in the user's
      repository, grep for it in node_modules/@fhevm/solidity/lib/FHE.sol.
      If it is not there, it does not exist in this version.
CR-3  Serialize fhevm.publicDecryptEuint and fhevm.userDecryptEuint calls
      in tests with sequential await. Never wrap them in Promise.all.
```

Each rule expanded in `references/core-rules.md`. These are the three most frequent failure modes; internalize them before writing any contract or test.

---

## Writing a new FHEVM contract

Step-by-step workflow:

1. **Start from the template.** Copy `templates/Contract.sol` to your `contracts/` directory. It contains the correct imports, inheritance from `ZamaEthereumConfig`, a constructor with initialization + ACL grants, and one example operation showing `FHE.fromExternal` + op + re-grant.

2. **Choose your encrypted types.** See `references/encrypted-types.md`. Default to `euint32` for counters and small quantities; `euint64` for token amounts; `euint8`/`ebool` for flags. Avoid `euint256` unless you need the range — it has limited op support.

3. **Handle inputs.** User-supplied encrypted inputs arrive as `externalEuint*` with an `inputProof`. Convert with `FHE.fromExternal(encInput, proof)`. See `references/input-proofs.md`.

4. **Apply ACL after every state-mutating op.** Per CR-1. Pattern:
   ```solidity
   _state = FHE.add(_state, amount);
   FHE.allowThis(_state);
   FHE.allow(_state, authorizedReader);
   ```

5. **For branching, use `FHE.select`.** Per refused pattern #5. See `references/operations.md`.

6. **For reveal, choose a decryption pattern.** Public (anyone decrypts off-chain via relayer) or user (specific address decrypts via EIP-712). See `references/decryption.md`.

7. **Run the lint check before finalizing.** `node scripts/lint-antipatterns.js` scans for the refused patterns above.

---

## Writing tests for an FHEVM contract

1. **Start from the template.** Copy `templates/Contract.test.ts`. It shows the full test pattern: `fhevm.createEncryptedInput`, contract call, `fhevm.publicDecryptEuint` or `fhevm.userDecryptEuint`, `bigint` assertions.

2. **Encrypted input construction:**
   ```typescript
   const encInput = await fhevm
     .createEncryptedInput(contractAddress, signer.address)
     .add32(5n)
     .encrypt();
   await contract.connect(signer).increment(encInput.handles[0], encInput.inputProof);
   ```

3. **Decryption in tests:**
   ```typescript
   const handle = await contract.getCount();
   const plaintext = await fhevm.userDecryptEuint(
     FhevmType.euint32,
     handle,
     contractAddress,
     signer
   );
   expect(plaintext).to.eq(5n);  // bigint literal — CR-3 consequence
   ```

4. **Per CR-3: never `Promise.all` decrypt calls.** If you have three tallies to decrypt, await them in sequence. See `references/testing.md` for the full explanation.

5. **Per CR-1: verify ACL by testing both success and revert paths.** For each address that should read an encrypted value, write a positive test (it reads and decrypts). For each address that should not, write a negative test (it reverts with "not allowed" or equivalent).

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Compile error: `FHE.requestDecryption` not found | Stale pre-v0.9 API | Refused pattern #1 — use `makePubliclyDecryptable` |
| Compile error: `SepoliaConfig` not exported | Stale pre-v0.10 config | Refused pattern #3 — use `ZamaEthereumConfig` |
| Runtime revert: `"not allowed"` on read | Missing `FHE.allow(handle, reader)` after op | CR-1 — re-grant ACL on new handle |
| Test error inside `node_modules/@fhevm/hardhat-plugin/.../BlockLogCursor` | `Promise.all` on decrypts racing the mock cursor | CR-3 — serialize decrypt awaits |
| `expect(plaintext).to.eq(5)` silently fails | `bigint` vs `number` strict equality | Use `.to.eq(5n)` — see `references/testing.md` |
| Revert on `FHE.fromExternal` | `inputProof` bound to wrong `(contract, sender)` | Regenerate input with correct contract address and caller |
| Contract compiles, test says "sender not authorized" | Encrypted input was encrypted under a different address | Match `createEncryptedInput(contract, signer)` to the address calling the function |

Full error catalog with causes and fixes in `references/troubleshooting.md`.

---

## How to read tags in reference files

Every behavioral claim in a reference file carries a provenance tag:

- `[mock-verified YYYY-MM-DD]` — confirmed via `@fhevm/hardhat-plugin` mock tests on the stated date
- `[sepolia-verified YYYY-MM-DD]` — confirmed via a live Sepolia deployment on the stated date
- `[docs-sourced]` — taken from Zama documentation, not lived through
- `[unverified]` — inferred or presumed; flagged for future verification

When a mock-verified claim is later confirmed on Sepolia, both tags are kept (both are true). When a claim fails Sepolia verification, the tag changes to `[mock-only — does not hold on Sepolia]` and the claim is revised.

This convention exists because mock-mode behavior occasionally diverges from live-chain behavior, and an agent reading the skill needs to know which claims are load-bearing for production work.

---

## Reference files

Load the relevant reference when working on that area:

- `references/core-rules.md` — CR-1, CR-2, CR-3 expanded with examples
- `references/anti-patterns.md` — every refused pattern with version history and replacement
- `references/encrypted-types.md` — type table, range, op support
- `references/operations.md` — arithmetic, comparison, `FHE.select`, HCU budget
- `references/access-control.md` — `allow` / `allowThis` / `allowTransient` / `isSenderAllowed`, decision tree
- `references/input-proofs.md` — `externalEuint*` + `inputProof`, relayer SDK, mock-mode equivalents
- `references/decryption.md` — public vs user decryption, v0.10+ patterns, off-chain relayer flow
- `references/frontend-integration.md` — thin pointer: `@zama-fhe/relayer-sdk` instance creation, gotchas; full examples in the demo repo
- `references/testing.md` — `fhevm` plugin API, CR-3 with full example, bigint assertion rule
- `references/troubleshooting.md` — error catalog

---

## Scripts

- `scripts/verify-env.sh` — the VERIFY gate. Run first, every session.
- `scripts/lint-antipatterns.js` — substring scan for refused patterns. Run before finalizing any contract or test file.

---

## Out of scope

This skill does not cover:
- ZK proofs, Noir, Circom, or other non-FHE privacy tech
- The Zama `fhevm-go` library (for chain integrators, not dApp developers)
- The `concrete` or `tfhe-rs` Rust libraries (for cryptographic primitive work, not Solidity)
- ERC-7984 token standard internals beyond what cUSDT requires (see OpenZeppelin `@openzeppelin/confidential-contracts`)

---

## Further reading

For conceptual background on FHE and FHEVM internals, see [docs.zama.ai/protocol](https://docs.zama.ai/protocol). This skill is operational; the docs are conceptual. Load the docs when the user asks "how does FHE work" or "why is this encrypted"; load this skill when the user asks "how do I write/test/debug FHEVM code."
