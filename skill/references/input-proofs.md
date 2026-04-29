# Input proofs — the encrypted-input round-trip

Version stamp: this file targets `@fhevm/solidity ≥0.10`, `@fhevm/hardhat-plugin ≥0.4`.

When a caller wants to pass an encrypted value into a contract, the value must be encrypted off-chain (frontend or test code), packaged with a proof, and submitted on-chain where the contract verifies the proof and converts the encrypted handle into a usable `euint*` type. This file covers the full round-trip.

Examples in this file that grant or transfer ACL carry an inline audit comment block — `// ACL on <handle>:` followed by per-address capabilities — when the "who can use what when" question is the lesson. Examples showing a syntactic shape (e.g., the `fromExternal` mechanism in §2.1) or trivial single-grant patterns omit the format. Same convention as `references/access-control.md`.

This file covers the input-proof round-trip:
```
§1  How input proofs are created (frontend / test side)
§2  How input proofs are verified and converted (on-chain side)
§3  Proof binding rules — (contract, sender) and what reverts
§4  The empty-proof / smart-contract-accounts path
§5  Cross-contract proof passing (and why it usually doesn't work)
§6  Anti-patterns specific to input proofs
```

---

## §1 — How input proofs are created (frontend / test side)

The plugin (test side) and the relayer SDK (frontend side) both expose the same conceptual interface: build an input bound to a `(contract address, sender address)` pair, add typed values, encrypt, receive handles plus a proof.

### 1.1 Test side — `@fhevm/hardhat-plugin`  [grep-verified; compile-verified 2026-04-29]

In Hardhat tests, the `fhevm` runtime helper exposes `createEncryptedInput`:

```typescript
createEncryptedInput(contractAddress: string, userAddress: string): RelayerEncryptedInput
```

Two parameters and only two: the address of the contract that will call `FHE.fromExternal`, and the address of the EOA that will call into that contract. These two addresses are the **binding** — see §3.

A typical test usage:

```typescript
const enc = await fhevm
    .createEncryptedInput(await contract.getAddress(), alice.address)
    .add32(42n)
    .encrypt();

await contract.connect(alice).setValue(enc.handles[0], enc.inputProof);
```

The chain `.add32(42n)` (or `.addBool(true)`, `.addAddress(...)`, `.add64(...)`, etc.) adds a typed value to the input. Multiple values can be packed into one input — call `.add32(...).add64(...).addBool(...)` in sequence, then `.encrypt()`. The result has a `handles` array (one entry per added value, in order) and a single `inputProof` covering all of them.

**Pack multiple values into one input when possible.** The proof is the expensive part of the round-trip; one proof covering three handles is cheaper than three independent proofs. [compile-shape-verified 2026-04-29; runtime behavior reasoned — we have not directly tested that one cryptographic proof verifies for multiple handles in the same call, only that the call shape compiles]

### 1.2 Frontend side — `@zama-fhe/relayer-sdk`  [docs-sourced]

The frontend equivalent uses the relayer SDK. The conceptual structure mirrors the plugin: create an instance, build an input bound to `(contract, sender)`, add typed values, encrypt:

```typescript
import { createInstance } from "@zama-fhe/relayer-sdk";

const instance = await createInstance({ /* network config */ });
const enc = instance
    .createEncryptedInput(contractAddress, signerAddress)
    .add32(42)
    .encrypt();

// enc.handles[0] is the externalEuint32; enc.inputProof is the bytes blob
await contractWithSigner.setValue(enc.handles[0], enc.inputProof);
```

The relayer SDK handles network-level concerns (talking to the coprocessor, fetching the public key for encryption, packaging the proof) that the test plugin handles internally. The contract-facing surface is identical — both produce `{handles, inputProof}` ready for `FHE.fromExternal`.

This file does not document the relayer SDK in depth. See `references/frontend-integration.md` for instance configuration, error handling, and React patterns.

---

## §2 — How input proofs are verified and converted (on-chain side)

### 2.1 The conversion function — `FHE.fromExternal`  [grep-verified; compile-verified 2026-04-29]

The contract receives `externalE*` types and converts them via `FHE.fromExternal`:

```solidity
function fromExternal(externalEuint32 inputHandle, bytes memory inputProof) internal returns (euint32);
```

Overloads exist for every usable type — `ebool`, `euint8`/`euint16`/`euint32`/`euint64`/`euint128`/`euint256`, `eaddress`. Eight conversion paths, one signature shape.

Standard usage:

```solidity
function setValue(externalEuint32 enc, bytes calldata proof) external {
    euint32 value = FHE.fromExternal(enc, proof);
    _state = value;
    FHE.allowThis(_state);
    FHE.allow(_state, msg.sender);
}
```

After `fromExternal`, the contract has transient ACL on the converted handle (see `references/access-control.md` §1.3). To persist the handle across transactions, call `allowThis` to upgrade the grant to persistent.

### 2.2 What `fromExternal` actually does  [grep-verified]

The function has two paths, gated on whether the proof is empty:

```solidity
function fromExternal(externalEuint32 inputHandle, bytes memory inputProof) internal returns (euint32) {
    if (inputProof.length != 0) {
        // Path 1: cryptographic proof verification
        return euint32.wrap(Impl.verify(externalEuint32.unwrap(inputHandle), inputProof, FheType.Uint32));
    } else {
        // Path 2: empty-proof fallback
        bytes32 inputBytes32 = externalEuint32.unwrap(inputHandle);
        if (inputBytes32 == 0) {
            return asEuint32(0);                                   // zero handle → trivial encryption
        }
        if (!Impl.isAllowed(inputBytes32, msg.sender)) {
            revert SenderNotAllowedToUseHandle(inputBytes32, msg.sender);
        }
        return euint32.wrap(inputBytes32);                          // non-zero handle, sender authorized
    }
}
```

Two paths, one function. The standard path (§3) is "proof present, cryptographically verified." The empty-proof path (§4) exists for smart-contract-account use cases where the handle is being re-passed by an address that already has ACL on it from a prior operation.

**This is not a security bypass.** Both paths enforce the same invariant — only authorized callers can introduce a handle into a contract — via different mechanisms. The cryptographic path verifies a proof; the empty-proof path checks existing ACL. An agent reading code that calls `fromExternal(handle, "")` should not assume the proof was forgotten or omitted; the empty-proof form is a deliberate library feature.

---

## §3 — Proof binding rules

### 3.1 The binding — `(contract address, sender address)`  [mock-verified 2026-04-29]

When a proof is created via `createEncryptedInput(contractAddress, userAddress)`, the resulting proof is bound to that exact `(contract, sender)` pair. At verification time, the cryptographic path checks both:

- The transaction's target contract must equal `contractAddress`.
- The transaction's caller (`msg.sender`) must equal `userAddress`.

Either mismatch causes the verification to revert.

### 3.2 The unified error — `InvalidSigner()`  [mock-verified 2026-04-29]

Both contract mismatch and sender mismatch fire the **same error**. The cryptographic verification does not distinguish them externally:

```
FHEVM Input verification error 'InvalidSigner()': The contract address
0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512 or signer account
0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 used in this transaction
differs from the values originally provided to the 'createEncryptedInput()'
function. Please ensure they match to avoid encryption errors.
```

The error name `InvalidSigner()` underspecifies — it suggests only the sender check, but fires on contract mismatch too. The enriched message correctly names both possibilities. An agent diagnosing this error should check both the target contract address *and* the sender, not just the sender.

This was empirically verified: a proof bound to `(contractA, alice)` submitted to `contractB` by alice fires the same `InvalidSigner()` as a proof bound to `(contractA, alice)` submitted by `bob` to `contractA`. The error class is unified; the diagnostic happens via the enriched message.

### 3.3 What this means in practice

Three rules an agent must internalize:

1. **A proof is single-target, single-caller.** It cannot be reused across contracts or across senders. Generating one proof and trying multiple combinations of `(target, caller)` will fail on every wrong combination.

2. **Frontend code that constructs the input must know both addresses up front.** `createEncryptedInput(contractAddress, signerAddress)` requires the contract being called and the wallet doing the calling — both at proof-creation time, before the transaction is sent.

3. **There is no "open" proof.** The library provides no mechanism for proofs that work for any contract, any caller, or any (contract × caller) combination. This is by design — open proofs would defeat the binding's purpose.

---

## §4 — The empty-proof / smart-contract-accounts path

Before this section's mechanism: this is an authorization path, not a verification skip. Both paths in `fromExternal` require the caller to be authorized for the handle. The cryptographic path verifies a fresh proof; the empty-proof path checks existing ACL. An agent reading code that calls `fromExternal(handle, "")` should not assume verification was bypassed.

### 4.1 What the empty-proof path does  [grep-verified; compile-verified 2026-04-29 for call shape]

When `inputProof.length == 0`, `fromExternal` skips cryptographic verification and instead:

1. If the handle is the zero handle (`bytes32(0)`), returns a trivially-encrypted zero. (Default-value path.)
2. Otherwise, checks whether `msg.sender` has ACL on the handle via `Impl.isAllowed`. If not, reverts with `SenderNotAllowedToUseHandle(handle, sender)`. If yes, returns the handle wrapped in the typed `euintXX`.

### 4.2 When this path matters  [reasoned]

The doc-comment in `FHE.sol` confirms the intent: this path "could facilitate integrating smart contract accounts with fhevm." The use case is account-abstraction wallets that have already had a handle authorized to them in a prior `UserOp` — they can re-pass that handle into a target contract without minting a fresh proof.

Concrete flow:

1. UserOp 1 calls `contractA.method()` with a fresh proof. `contractA` does `FHE.fromExternal(handle, proof)`, gets the handle, calls `FHE.allow(handle, userOpSender)` so the AA sender has persistent ACL.
2. UserOp 2 (same AA bundle, same sender) calls `contractB.method(handle, "")`. `contractB` does `FHE.fromExternal(handle, "")` — empty-proof path — and the call succeeds because `Impl.isAllowed(handle, msg.sender)` is true from step 1's grant.

This pattern avoids re-generating a fresh proof for every contract call when the same handle flows through multiple contracts in the same logical user action.

### 4.3 The empty-proof error — `SenderNotAllowedToUseHandle`  [grep-verified]

If the empty-proof path runs and the sender lacks ACL on the handle, the function reverts with:

```solidity
error SenderNotAllowedToUseHandle(bytes32 handle, address sender);
```

This is a different error from `InvalidSigner()`. An agent diagnosing a `fromExternal` revert should check which error fired:

- `InvalidSigner()` → cryptographic path; proof is present but does not match the current `(contract, sender)`. Fix: regenerate the proof with the correct binding.
- `SenderNotAllowedToUseHandle` → empty-proof path; proof is absent and the sender lacks ACL on the handle. Fix: either grant the sender ACL via `FHE.allow` in a prior call, or supply a proof.

---

## §5 — Cross-contract proof passing  [reasoned]

A common question: can a contract receive an `(externalEuint32, bytes)` pair, pass it to another contract's `fromExternal`, and have the second contract accept it?

**Generally no.** The proof's binding is to the contract that the user originally passed to `createEncryptedInput` — typically the first contract in the call chain, not the second. If the second contract is the one calling `fromExternal`, the binding check fails because `address(this)` at the verification site differs from the contract in the binding.

```solidity
// This pattern does not work:
contract Forwarder {
    function forward(IDownstream target, externalEuint32 enc, bytes calldata proof) external {
        target.acceptInput(enc, proof);  // target's fromExternal call will revert
    }
}

contract Downstream {
    function acceptInput(externalEuint32 enc, bytes calldata proof) external {
        euint32 value = FHE.fromExternal(enc, proof);
        // InvalidSigner() — proof was bound to Forwarder, not Downstream
    }
}
```

The fix depends on the use case:

**Option A: Bind the proof to the downstream contract directly.**  [reasoned] The frontend constructs the input with `createEncryptedInput(downstreamAddress, signerAddress)` and the user calls `Downstream.acceptInput(...)` directly, with `Forwarder` not in the picture. This is the simplest fix when the indirection isn't load-bearing.

**Option B: Use the empty-proof path.**  [reasoned] If `Forwarder` has been granted ACL on the handle (via `allow` or `allowTransient` from a prior step), it can pass the handle to `Downstream` with an empty proof — `Downstream`'s `fromExternal(handle, "")` will succeed because the empty-proof path's `Impl.isAllowed(handle, msg.sender)` check passes when `msg.sender` (`Forwarder` in this call) has ACL. AA-wallet bundles work the same way: the wallet itself is the direct `msg.sender` in each UserOp call, so a wallet that has ACL on a handle from UserOp 1 can pass it with an empty proof in UserOp 2. The mechanism does not work for a regular EOA going through a `Forwarder` unless the `Forwarder` itself was granted ACL.

**Option C: Forwarder calls `fromExternal` itself, then re-grants.**  [compile-verified 2026-04-29; behavior reasoned] `Forwarder` does `FHE.fromExternal(enc, proof)` — proof was bound to `Forwarder`, succeeds — gets the converted `euint32`, calls `FHE.allowTransient(handle, address(downstream))`, then calls `Downstream` with the *handle* (not the external+proof pair). `Downstream`'s function takes `euint32` directly, no `fromExternal` needed.

```solidity
contract Forwarder {
    function forward(IDownstream target, externalEuint32 enc, bytes calldata proof) external {
        euint32 value = FHE.fromExternal(enc, proof);  // proof bound to Forwarder
        FHE.allowTransient(value, address(target));
        target.process(value);
        // ACL on value during this tx:
        //   contract (Forwarder): uses (auto-granted by fromExternal)
        //   target (Downstream): uses for this tx only
        //   everyone else: cannot read
    }
}

contract Downstream {
    function process(euint32 value) external {
        // No fromExternal — value is already a euint32 with transient ACL granted to this contract
        euint32 doubled = FHE.add(value, value);
        FHE.allowThis(doubled);
        // ACL on doubled:
        //   contract (Downstream): uses in subsequent ops
        //   everyone else: cannot read
    }
}
```

This is the canonical pattern for cross-contract handoff — bind the proof to the entry contract, do the conversion there, and pass the converted handle (not the proof) downstream.

**What's `[reasoned]` here:** the description of where the binding fails and why is reasoned from the verified `(contract, sender)` binding rule plus the empty-proof path's ACL check. I have not directly compile-tested options A and B end-to-end in coordinated multi-contract setups, but option C is the same pattern as the cross-contract handoff in `access-control.md` §5, which is `[compile-verified]` for the syntactic shape via the helper-contract example there.

---

## §6 — Anti-patterns specific to input proofs

### 6.1 Reusing a proof across contracts  [mock-verified 2026-04-29]

```solidity
// BROKEN — proof is bound to one specific contract
const enc = await fhevm.createEncryptedInput(contractA.address, alice.address).add32(42n).encrypt();

await contractA.setValue(enc.handles[0], enc.inputProof);   // works
await contractB.setValue(enc.handles[0], enc.inputProof);   // reverts: InvalidSigner()
```

Each contract that needs to receive an encrypted input requires its own proof, generated against that contract's address. Generate a separate proof per target.

### 6.2 Reusing a proof across senders  [mock-verified 2026-04-29]

```solidity
// BROKEN — proof is bound to one specific sender
const enc = await fhevm.createEncryptedInput(contract.address, alice.address).add32(42n).encrypt();

await contract.connect(alice).setValue(enc.handles[0], enc.inputProof);   // works
await contract.connect(bob).setValue(enc.handles[0], enc.inputProof);     // reverts: InvalidSigner()
```

A proof generated for alice cannot be used by bob, even on the same target contract.

### 6.3 Submitting an empty proof on a handle the sender doesn't own  [grep-verified]

```solidity
// BROKEN — empty-proof path, sender lacks ACL
await contract.setValue(someHandle, "0x");   // reverts: SenderNotAllowedToUseHandle
```

The empty-proof path is not a "skip verification" shortcut. It requires existing ACL on the handle. If the calling pattern doesn't fit the AA-wallet use case described in §4, supply a proof.

### 6.4 Confusing the two error modes during diagnosis  [grep-verified for both error names]

`InvalidSigner()` and `SenderNotAllowedToUseHandle` look related but indicate different failure paths:

- `InvalidSigner()` → cryptographic path failed. The proof is present but doesn't match `(current contract, current sender)`. Regenerate the proof.
- `SenderNotAllowedToUseHandle` → empty-proof path failed. The proof is absent and the sender lacks ACL on the handle. Either grant ACL before this call, or supply a proof.

An agent diagnosing one of these errors should not propose fixes that apply to the other class.

---

## What this file does not cover

- **Relayer SDK initialization, network configuration, and React patterns.** See `references/frontend-integration.md`.
- **The cryptographic primitives behind `Impl.verify`.** Outside this skill's scope.
- **Specific gas / HCU costs of `fromExternal`.** Document-side; numbers go stale. Per-op costs are documented in Zama's HCU cost tables.
- **Decryption of the converted handle.** Once the handle is inside the contract, decryption is a separate flow. See `references/decryption.md`.

---

## Cross-references

- ACL on the converted handle — `references/access-control.md` §1.3 (auto-grant note) and §5 (cross-contract patterns)
- Operations on the converted `euint*` — `references/operations.md`
- Frontend instance setup and React patterns — `references/frontend-integration.md`
- Diagnosing the two error classes — `references/troubleshooting.md`
