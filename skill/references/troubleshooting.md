# Troubleshooting — error catalog and triage

Version stamp: this file targets `@fhevm/solidity ≥0.10`, `@fhevm/hardhat-plugin ≥0.4.2`, `@zama-fhe/relayer-sdk ≥0.4`.

This file is the canonical entry point for diagnosing FHEVM errors. Most error-specific treatment lives in the reference file that owns the underlying mechanism — this file is a cross-reference catalog organized by *when* the error fires (compile-time, runtime, test-time, frontend), with pointers to the substantive treatment elsewhere.

```
§1  Where to find diagnostic content in this skill (cross-ref map)
§2  Compile-time errors
§3  Runtime reverts
§4  Test-time failures
§5  Frontend-side errors
§6  Triage workflow for a new error not in the catalog
```

---

## §1 — Where to find diagnostic content in this skill

Each reference file owns the diagnostic surface for the mechanism it documents. This file points you at the right one based on the symptom; the named file owns the explanation and fix.

| Symptom domain | Owning file |
|---|---|
| ACL grant failures (`not allowed`, missing `allowThis`) | `references/access-control.md` §1, §3.1 |
| Input-proof binding mismatches (`InvalidSigner`, `SenderNotAllowedToUseHandle`) | `references/input-proofs.md` §3, §4 |
| Decryption flow failures (public, user, delegated) | `references/decryption.md` §5 |
| Mock-mode test flakes (cursor race, bigint mismatches) | `references/testing.md` §4, §5 |
| Frontend SDK init/wallet errors | `references/frontend-integration.md` §2.3, §3.2 |
| Pre-v0.9 API references (`requestDecryption`, `Gateway*`, `SepoliaConfig`) | `references/anti-patterns.md` §1 |
| Type-selection mistakes (`euint256` arithmetic, orphan widths) | `references/encrypted-types.md` §4, §5 |

Use this catalog when an error's mechanism is unclear from its message. The catalog below names the specific error strings and points at the owning file.

---

## §2 — Compile-time errors

Solidity compile errors that surface from FHEVM-specific causes.

| Error | Cause | Fix | Owner |
|---|---|---|---|
| `Error HH411: The library fhevm, imported from ..., is not installed.` | Stale pre-v0.7 import from `fhevm/lib/TFHE.sol`. **Hardhat suggests `npm install fhevm` — do not follow this; it installs the unmaintained legacy package.** | Rewrite import as `import {FHE, ...} from "@fhevm/solidity/lib/FHE.sol"`. Rename `TFHE.X` → `FHE.X`. | `anti-patterns.md` §1.4 |
| `DeclarationError: Identifier not found or not unique.` on `einput` | Pre-v0.7 type name. | Use `externalEuint32` (or appropriate width) and convert via `FHE.fromExternal`. | `anti-patterns.md` §1.5 |
| `DeclarationError: Identifier not found or not unique.` on `ebytes32` | The type is declared in `encrypted-types/EncryptedTypes.sol` but not imported into the calling file (pre-v0.7 used implicit availability via `TFHE` import). | Import explicitly: `import {ebytes32} from "encrypted-types/EncryptedTypes.sol";` if your version supports it. Often the design wants `bytes` plus frontend encryption instead. | `anti-patterns.md` §1.6 |
| `DeclarationError: Declaration "SepoliaConfig" not found in "@fhevm/solidity/config/ZamaConfig.sol"` | Pre-v0.10 per-network config. | Use `ZamaEthereumConfig` — single config for all Ethereum-side networks. | `anti-patterns.md` §1.3 |
| `Error: Unresolved-function 'mul' on euint256` (or similar arithmetic op) | `euint256` has bitwise/equality only — no arithmetic, no ordering. | Use `euint64` or `euint128` for arithmetic; reserve `euint256` for hashes/bitfields. | `encrypted-types.md` §4.1 |
| Compile error on `if (someEbool)` or `require(someEbool)` | Cannot branch Solidity control flow on encrypted values. | Use `FHE.select(cond, ifTrue, ifFalse)` for conditional encrypted values; restructure if a plaintext branch is required. | `anti-patterns.md` §4.1 |
| Compile error on assignment without re-grant pattern | Not a literal compile error, but the contract compiles and then runtime ACL fails. See §3. | Re-grant with `FHE.allowThis` after every FHE op. | `core-rules.md` CR-1 |

**Triage rule for compile errors:** the message names the symbol or the file. Grep the installed library (`node_modules/@fhevm/solidity/lib/FHE.sol`) for the symbol; if it's absent, the symbol was removed or renamed in the version you have. See `core-rules.md` CR-2.

---

## §3 — Runtime reverts

Reverts that fire during transaction execution.

| Error | Cause | Fix | Owner |
|---|---|---|---|
| `Error: not allowed` (or library-specific ACL revert) on a state read | The reading address has no ACL on the handle. | Add `FHE.allow(handle, addr)` after the op that produced the handle. The grant is per-handle, not per-variable. | `access-control.md` §1, `core-rules.md` CR-1 |
| `Error: not allowed` on a contract-internal op | Contract lacks `allowThis` on a handle it just received via `FHE.add`/`FHE.sub`/etc. | Re-grant `FHE.allowThis(handle)` after every state-mutating FHE op. | `core-rules.md` CR-1 |
| `InvalidSigner()` (with enriched message naming contract and signer) | `FHE.fromExternal` cryptographic-path verification rejected the proof. The proof's `(contract, sender)` binding does not match the current call's contract address or `msg.sender`. **The error name suggests "signer" only; it fires on contract mismatch too.** | Regenerate the input via `createEncryptedInput(actualContractAddress, actualSignerAddress)` and resubmit. Verify both addresses match. | `input-proofs.md` §3.2 |
| `SenderNotAllowedToUseHandle(handle, sender)` | `FHE.fromExternal` empty-proof path: the proof was empty (length 0) and `msg.sender` lacks ACL on the handle. | Either supply a proof, or grant the sender ACL on the handle in a prior call. The empty-proof path is for AA-wallet flows where ACL was granted upstream. | `input-proofs.md` §4.3 |
| `revert` on `FHE.div` or `FHE.rem` with encrypted divisor | Division accepts only plaintext divisor. `FHE.div(euint, uint)` works; `FHE.div(euint, euint)` does not exist. | Use a plaintext divisor, or restructure to avoid division by encrypted values (often a design issue). | `operations.md` §3.4 |
| Silent zero-decryption from `FHE.makePubliclyDecryptable` | The handle was uninitialized when the function was called. The library substitutes a type-default (zero/false/`address(0)`) silently. | If the contract needs to distinguish "value was zero" from "value was never set," track the distinction in a separate boolean state variable. | `decryption.md` §2.3 |
| HCU-exhaustion revert on a function with loops over encrypted state | FHE operations cost much more than EVM ops; loops over encrypted state can blow the HCU budget. | Restructure to fixed-size or bounded patterns; consult Zama's HCU cost tables for current limits. | `operations.md` §4 |

**Triage rule for runtime reverts:** check the error name first. Custom errors (`InvalidSigner`, `SenderNotAllowedToUseHandle`) come from named library checks and have specific fixes. Generic `revert` without a reason often points at ACL — the most common production runtime failure mode is missing `allowThis` after an op.

---

## §4 — Test-time failures

Failures that surface only in mock-mode test runs.

| Symptom | Cause | Fix | Owner |
|---|---|---|---|
| `AssertionError: expected 5n to equal 5` | Bigint vs number mismatch. The decrypt helpers for `euint*` types return `bigint`; the assertion compared against `number`. | Use `.to.eq(5n)` with the `n` literal suffix, or wrap with `BigInt()`. | `testing.md` §4.2 |
| Test passes for one decrypt call, fails for two via `Promise.all` with internal stack inside `BlockLogCursor.updateForward` | Mock-coprocessor cursor race: concurrent decrypt requests advance an internal cursor non-atomically. | Replace `Promise.all([...decryptCalls])` with sequential `await` per call. CR-3. | `testing.md` §5.1, `core-rules.md` CR-3 |
| `expect(handle).to.eq(ethers.ZeroHash)` fails on a fresh state variable | The handle was initialized in the constructor (e.g., `FHE.asEuint32(0)`) — it's a real handle, not the zero hash. | Either omit constructor initialization (then `_state` defaults to `bytes32(0)` which equals `ZeroHash`), or assert via decryption (`fhevm.userDecryptEuint` and `expect(value).to.eq(0n)`). | `testing.md` §3 |
| Test silently passes when it should fail on encrypted input mismatch | Test forgot to `await` `.encrypt()` on the input chain — passes a Promise object to the contract, which Solidity coerces silently. | Always `await fhevm.createEncryptedInput(...).add32(...).encrypt()`. | `testing.md` §3 |
| `Error: cannot decrypt` or similar opaque mock failure | Common cause: the test is exercising a flow the mock cannot simulate (e.g., live relayer auth). | Skip mock-only tests in live mode via `if (!fhevm.isMock) this.skip();`. For tests that need live behavior, run against Sepolia (see `testing.md` §6). | `testing.md` §2.1, §6 |
| `revertedWithCustomError` matcher does not match the expected error | The custom error is in the inherited library, not the contract's own surface. Or the error name is misspelled. | For contract-defined errors, ensure the error is declared in the contract (or imported). For library-internal errors, fall back to `to.be.reverted` without a specific reason. | `testing.md` §5.2 |

**Triage rule for test failures:** the bigint trap and the Promise.all race together account for a large share of test-time confusion. If a test is failing in unexpected ways, check those two first before suspecting the contract.

---

## §5 — Frontend-side errors

Errors that surface in browser or Node.js code that calls the relayer SDK.

| Symptom | Cause | Fix | Owner |
|---|---|---|---|
| First SDK call fails with "WASM not loaded" or similar | Web environment without `initSDK()`. The web entry requires WASM init before `createInstance`. | Call `await initSDK()` first. Node-side scripts skip `initSDK` (it doesn't exist there). | `frontend-integration.md` §2.3 |
| `initSDK()` returns `false` instead of throwing | `initSDK` reports failure via boolean return, not exception. | Check the return value: `const ok = await initSDK(); if (!ok) throw ...`. | `frontend-integration.md` §2.3 |
| `userDecrypt` rejected by relayer with signature error | EIP-712 signature mismatch. Common causes: signer address differs from `userAddress` parameter; chain ID mismatch in EIP-712 domain; validity-window parameters differ between `createEIP712` and `userDecrypt`. | Verify all three: signer matches `userAddress`, wallet is on the expected chain, and `startTimestamp`/`durationDays` are identical between the two calls. | `decryption.md` §3.5, `frontend-integration.md` §3.2 |
| `userDecrypt` rejected with ACL error on the handle | The address requesting decryption lacks on-chain ACL on the handle. | Call `FHE.allow(handle, userAddress)` on-chain in a prior transaction. Delegation does not bypass this; the delegator must have ACL on the handle for delegated decryption to succeed. | `access-control.md` §1.2, `decryption.md` §4 |
| `delegatedUserDecrypt` rejected with delegation-not-found | On-chain delegation was not established or has expired. | Call `FHE.delegateUserDecryption(delegate, contract)` from the delegator's address. Check expiration via `FHE.getDelegatedUserDecryptionExpirationDate`. | `access-control.md` §3.3, `decryption.md` §4 |
| Wallet signature prompt cancelled by user (EIP-1193 error code 4001) | User clicked Reject in the wallet popup. | Surface in UX as a "user cancelled" state distinct from "decryption failed". | `frontend-integration.md` §3.2 |
| `publicDecrypt` returns a default value (zero/false/`address(0)`) instead of expected data | Either the handle was uninitialized when `makePubliclyDecryptable` was called (silent default substitution), or the handle was not marked publicly decryptable on-chain. | Verify `FHE.makePubliclyDecryptable(handle)` was called on a populated handle. Track "value was set" separately if the contract needs the distinction. | `decryption.md` §2.3, §5 |
| Account-switch mid-flow: signature is from a different address than expected | User switched wallet accounts after `createEIP712` but before signing. | Pin the signing account at flow start; verify it matches before submitting. | `frontend-integration.md` §3.2 |

**Triage rule for frontend errors:** check the wallet boundary first. Most "SDK errors" originate at the wallet layer (chain mismatch, account switch, signature rejection) rather than in the SDK itself. The SDK passes wallet errors through transparently.

---

## §6 — Triage workflow for a new error not in the catalog

When you encounter an error not documented above, work through these steps in order. Stop when the error reproduces with new information.

1. **Read the full error message and stack.** FHEVM errors often have informative enriched messages (`InvalidSigner` includes the contract and signer addresses). The plugin's runtime helpers wrap raw library errors with diagnostic text. The first line of the message often names the function that failed.

2. **Identify which layer produced the error.**
   - Solidity compile-time → §2 of this file.
   - Solidity runtime → §3.
   - TypeScript test-time → §4.
   - JavaScript / browser frontend → §5.
   - The layer scopes which reference file owns the diagnostic.

3. **Grep the installed library for symbols named in the error.** Per CR-2, `node_modules/@fhevm/solidity/lib/FHE.sol` is the source of truth for what exists. If the error names a symbol that grep doesn't find, the symbol was removed or renamed and your code is using a stale API.

4. **Check version stamps.** The reference files declare which versions they target. If the installed packages are newer or older, behavior may have changed. Run `bash skill/scripts/verify-env.sh` to confirm the installed versions and the canonical symbol presence.

5. **Reproduce minimally.** Strip the failing test or function down to the minimum that reproduces. Often the minimal version makes the cause obvious — and if it doesn't, the minimal repro is what you'd file as a bug report or paste into a question.

6. **Check the FOOTGUN_LOG.md.** Substantive findings from the skill's authoring are documented there with original error strings. Some errors map to entries we already wrote.

7. **If still stuck, the error is a candidate for adding to this skill.** Capture the symptom, the cause, the fix, and add an entry to the appropriate section of this file. Public errors documented across the catalog become public diagnostic surface.

---

## What this file does not cover

- **Sepolia-specific deployment errors** (RPC issues, gas pricing, account balance). These are general Ethereum-deployment concerns documented in Hardhat's own diagnostic surface; not FHEVM-specific.
- **Performance debugging** (slow tests, slow frontend decryption). The mock is fast; the live coprocessor's latency depends on network and load. See `operations.md` §4 for the HCU concept and Zama docs for current performance characteristics.
- **Cross-version migration errors** (e.g., upgrading from `@fhevm/solidity` 0.10 to a future 0.11). Migration paths depend on the specific version delta and are documented in Zama's release notes.

---

## Cross-references

- The substantive treatment of every error class named in this catalog lives in the reference file linked in the right-hand column. This file is the catalog; those files are the explanations.
- For new errors caught during skill development, see `FOOTGUN_LOG.md` for the original captures and the verification process that produced them.
