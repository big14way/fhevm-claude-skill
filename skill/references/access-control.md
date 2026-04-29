# Access control — ACL grants, decision tree, and the append-only constraint

Version stamp: this file targets `@fhevm/solidity ≥0.10`.

FHEVM's access control list (ACL) is the most subtle layer of the library. Every encrypted handle has an ACL — a set of addresses authorized to use or decrypt that handle. ACL is the gating mechanism between encrypted state and plaintext: an address with no ACL on a handle cannot decrypt it, no matter how the handle was produced or who contributed to it.

Three rules govern every ACL decision:

1. **ACL is per-handle, not per-variable.** Every `FHE.*` operation that returns a value produces a new handle, and the new handle has zero ACL until granted. Re-grant after every op. (See `references/core-rules.md` §CR-1 for the full statement.)
2. **ACL grants are append-only.** There is no `revokeAllow` or equivalent on the per-handle grant surface. Once an address has ACL on a handle, it has it for the lifetime of that handle. The only way to "remove" access is to produce a new handle the old recipient was never granted on.
3. **ACL follows handle production, not data contribution.** A user who supplies an encrypted input does not gain ACL on the result. The contract that produces the new handle decides who reads it. (See `references/core-rules.md` §CR-1's conceptual sharpening.)

This file documents the ACL function surface, when to use which variant, the per-voter-vs-aggregate pattern that's the canonical leak, and the two adjacent revocable surfaces (user-decryption delegation, deny list) that exist *separately* from per-handle grants.

---

## 1. The grant functions  [grep-verified]

The library exposes three grant functions. Each takes a handle and returns the same handle (chainable via `using FHE for *`); agents typically call them as statements.

```solidity
FHE.allowThis(euint32 handle) returns (euint32);
FHE.allow(euint32 handle, address account) returns (euint32);
FHE.allowTransient(euint32 handle, address account) returns (euint32);
```

Same overloads exist for every usable type — `ebool`, `eaddress`, all `euint*` standard widths.

### 1.1 `FHE.allowThis(handle)` — the contract grants itself  [grep-verified; compile-verified 2026-04-19 via E1]

Required after every operation that produces a new handle the contract intends to use again in a subsequent call. Without `allowThis`, the contract loses the ability to operate on the handle in any future transaction.

```solidity
_count = FHE.add(_count, amount);
FHE.allowThis(_count);
// ACL on _count:
//   contract: uses in subsequent ops
//   everyone else: cannot read
```

`allowThis` is **persistent** — the grant survives across transactions. It is the default grant for any state variable the contract reads or writes across functions.

### 1.2 `FHE.allow(handle, address)` — persistent grant to an external address  [grep-verified; compile-verified 2026-04-19 via E1]

Grants an address — EOA or contract — the right to decrypt the handle off-chain via the relayer SDK. The grant is persistent: it survives across transactions for the lifetime of the handle.

```solidity
_count = FHE.add(_count, amount);
FHE.allowThis(_count);
FHE.allow(_count, owner);
// ACL on _count:
//   contract: uses in subsequent ops
//   owner: decrypts off-chain
//   everyone else: cannot read
```

The `address` parameter is the literal address that gains decryption rights. There is no ACL group, role, or wildcard — every authorized reader is named individually. A contract that wants "all current voters" to read a handle would need to call `FHE.allow(handle, voterN)` once per voter, individually.

### 1.3 `FHE.allowTransient(handle, address)` — single-transaction grant  [grep-verified; compile-verified 2026-04-19 via E2]

Grants the address ACL on the handle, but only for the remainder of the current transaction. At the end of the transaction, the grant is automatically cleared.

```solidity
function processBatch(externalEuint32 enc, bytes calldata proof) external {
    euint32 amount = FHE.fromExternal(enc, proof);
    FHE.allowTransient(amount, address(processor));
    processor.process(amount);
    // After this transaction, address(processor) loses ACL on amount automatically.
}
// ACL on amount during this tx only:
//   contract: uses (created via fromExternal which auto-grants)
//   processor: uses for the duration of this transaction
//   everyone else: cannot read
```

**Note on `fromExternal` and auto-grants.** `FHE.fromExternal` automatically grants the calling contract transient ACL on the resulting handle — that's why no explicit `allowThis` is needed before the helper call in the example above. If the contract wants persistent ACL on the handle (to use it in a later transaction or store it as state), it must call `allowThis` explicitly to upgrade the transient grant to persistent. [reasoned — inferred from the working pattern across our reference contracts; not directly compile-tested via a fromExternal-then-op-without-allowThis case]

Use `allowTransient` when passing a handle to a helper contract within a single transaction and you want the grant to vanish after. The transient grant is **not** stored persistently on-chain, which makes it cheaper than `allow` and prevents grant accumulation over time.

**Pitfall — Account abstraction batching.** Multiple `UserOps` in a single bundled AA transaction share transient storage. If `UserOp 1` calls `allowTransient(handle, B)` and `UserOp 2` runs in the same tx, `UserOp 2` sees the grant. This is rarely the desired behavior — operations bundled by an AA wallet should typically not share ACL grants. To prevent inheritance, call `FHE.cleanTransientStorage()` between operations (see §3.2).

---

## 2. Decision tree — which grant for which case  [reasoned]

Agents most often pick the wrong grant variant by reaching for the most familiar (`allow`) when a transient grant or a self-grant would be correct. Use this tree:

```
Does the contract need to read or operate on the handle in a future transaction?
  YES → FHE.allowThis(handle)            (always required for persistent state)

Does an external address (EOA or contract) need ACL on this handle?
  ├── Persistently, across multiple transactions, for off-chain decryption?
  │     YES → FHE.allow(handle, address)
  │
  └── Only during this single transaction (cross-contract handoff for FHE
      ops, OR one-shot decryption batched with other state)?
        YES → FHE.allowTransient(handle, address)
              (cheaper, auto-cleared, prevents grant accumulation)

Common combinations:
  • State variable owner can decrypt: allowThis + allow(handle, owner)
  • Cross-contract handoff this tx only: allowTransient(handle, helperContract)
  • Multi-grant per state update: allowThis + allow(...) for each authorized reader
```

The most common mistake is calling only `allow(handle, owner)` and omitting `allowThis(handle)` — the owner can decrypt, but the contract can no longer operate on the handle in a subsequent function call. Always grant the contract first.

---

## 3. Adjacent surfaces — what looks like ACL but isn't

### 3.1 ACL grants are append-only — no per-handle revocation  [grep-verified for absence; compile-verified 2026-04-19 for pattern via E3]

**The only path to revocation: produce a fresh handle and don't re-grant on it.** This section's takeaway in one sentence; the rest is mechanism.

The library does not provide `revokeAllow`, `disallow`, `removeAllow`, or any equivalent function that takes a handle and an address and removes a previously-granted ACL. Verified by grep across `FHE.sol` for the full set of revoke-flavored function names; no match takes a ciphertext-shaped argument.

**Implication:** Once an address has ACL on a handle, it has it for the lifetime of that handle. The only way to "remove" access is to produce a new handle (via any FHE op) and not grant the address on the new one.

```solidity
// Cannot do this:
// FHE.disallow(_balance, formerOwner);   // function does not exist

// Can do this — produce a new handle and don't re-grant to formerOwner:
_balance = FHE.add(_balance, FHE.asEuint32(0));   // op produces new handle
FHE.allowThis(_balance);
FHE.allow(_balance, currentOwner);
// formerOwner had ACL on the old handle, has none on this new handle.
// ACL on _balance:
//   contract: uses in subsequent ops
//   currentOwner: decrypts off-chain
//   everyone else (including formerOwner): cannot read
```

This pattern — "produce a fresh handle to drop legacy grants" — is the only revocation mechanism for per-handle ACL. The trivial `FHE.add(_, FHE.asEuint32(0))` is a no-op for the value but a real op for the handle, which is what we need.

### 3.2 `cleanTransientStorage()` — global, bundled, per-transaction  [grep-verified via source read; compile-verified 2026-04-19 for call shape via E6]

```solidity
function cleanTransientStorage() internal {
    Impl.cleanTransientStorageACL();
    Impl.cleanTransientStorageInputVerifier();
}
```

No parameters. Global. Clears two distinct transient stores in one call:

1. **Transient ACL grants** — every `allowTransient` grant made earlier in the current transaction is removed.
2. **Input verifier transient state** — internal state used by `FHE.fromExternal` to validate input proofs is reset.

**Footgun:** an agent calling `cleanTransientStorage()` mid-transaction to "clean up my transient ACL grants" also wipes input-verifier state. Any in-flight `FHE.fromExternal` operation later in the same transaction will fail or re-validate from scratch. The bundling is not selectable — there is no `cleanTransientStorageACL()`-only public function exposed.

**When to use it:**

- Between bundled `UserOps` in account-abstraction transactions, to prevent transient grants from leaking across operations.
- At the end of a function that made transient grants, if and only if the function is the last thing in its transaction (or no further `fromExternal` calls follow).

**When not to use it:**

- Mid-transaction in any contract that calls `FHE.fromExternal` later in the same tx.
- As a "defensive cleanup" on every function exit. The overhead is real and the bundled effect on input verification can produce hard-to-diagnose failures.

### 3.3 User-decryption delegation — a separate, revocable surface  [grep-verified for existence]

The library exposes a delegation surface for user decryption — letting one address authorize another to decrypt-on-its-behalf via the relayer. This is **not** the same as ACL grants. ACL controls who can decrypt a handle; delegation controls who can act-as-someone-else-when-decrypting.

The delegation surface includes (verified by grep):

```solidity
function revokeUserDecryptionDelegation(address delegate, address contractAddress);
function revokeUserDecryptionDelegations(...);
```

Notably, **delegation is revocable** (these functions exist) while per-handle ACL grants are not. An agent who reads "ACL is append-only" should not generalize to "the library has no revocation surface" — delegation is the exception.

This file does not document the delegation surface in detail because it is rare in practice and orthogonal to ACL design. If a contract needs delegation, see `references/decryption.md` and the relayer SDK docs for the user-decryption flow.

For the substantive treatment of delegation — the six on-chain functions, the parallel SDK flow, and when to use it — see `references/decryption.md` §4.

### 3.4 The deny list — exists, scope deferred  [grep-verified for existence]

`FHE.sol` line 9325 references a deny list (doc comment: "Returns whether the account is on the deny list"). This is a separate concept from per-handle ACL — likely a KMS-level or coprocessor-level account blocklist that overrides individual grants.

Surface details, who controls the list, and how it interacts with grants are not documented in this skill. If a contract needs to reason about deny-listed accounts, grep `FHE.sol` for `denyList` for the current surface and consult Zama docs.

---

## 4. The per-voter / aggregate pattern — the canonical ACL leak

This is the most important pattern in this file. It is the only ACL leak that is silent in mock-mode tests, compiles cleanly, and produces a confidentiality failure in production. (See `references/anti-patterns.md` §4.2 for the refusal-pattern framing.)

### 4.1 The wrong pattern — granting `msg.sender` on aggregate state  [reasoned for mechanism; wrong-pattern code shape compile-verified 2026-04-19 (subset of E4)]

```solidity
// LEAKS — every voter can decrypt the running tally of all votes
function vote(externalEuint32 encWeight, bytes calldata proof) external {
    euint32 weight = FHE.fromExternal(encWeight, proof);
    _tally = FHE.add(_tally, weight);
    FHE.allowThis(_tally);
    FHE.allow(_tally, msg.sender);    // WRONG
}
// ACL on _tally:
//   contract: uses in subsequent ops
//   msg.sender: decrypts the AGGREGATE tally, including everyone else's contributions
//   everyone else: cannot read (but every prior voter already had this grant on their iteration)
```

Why it happens: standard Solidity intuition says "the user contributed to this state, they should be able to read it." In FHEVM, ACL is per-handle, and the handle is the aggregate.

**The precise mechanism of the leak.** Each `vote` call produces a new handle of `_tally` (per CR-1, every FHE op produces a new handle). The `FHE.allow(_tally, msg.sender)` grant attaches only to *that call's* handle — the running total at that moment in time. So `msg.sender` doesn't gain access to the final aggregate after all votes complete; they gain access to the running total up through their own vote.

The cumulative effect across many votes: voter N can decrypt the prefix sum of votes 1..N. Voter 1 sees only their own contribution. Voter 2 sees the sum of votes 1+2. Voter 3 sees votes 1+2+3. Each voter learns more than just their own contribution — they learn about all prior voters in aggregate. This is a confidentiality failure, just not the "everyone sees the final tally" framing one might initially assume. [reasoned — not compile-tested via multi-voter scenario; pattern follows from CR-1's per-handle ACL rule]

### 4.2 The right pattern — per-voter storage with per-voter ACL  [compile-verified 2026-04-19 via E4]

```solidity
mapping(address => euint32) voterContribution;
euint32 _tally;

function vote(externalEuint32 encWeight, bytes calldata proof) external {
    euint32 weight = FHE.fromExternal(encWeight, proof);

    // Per-voter storage — voter reads their own contribution only
    voterContribution[msg.sender] = weight;
    FHE.allowThis(voterContribution[msg.sender]);
    FHE.allow(voterContribution[msg.sender], msg.sender);
    // ACL on voterContribution[msg.sender]:
    //   contract: uses in subsequent ops
    //   msg.sender: decrypts own contribution off-chain
    //   everyone else: cannot read

    // Aggregate — only admin reads
    _tally = FHE.add(_tally, weight);
    FHE.allowThis(_tally);
    FHE.allow(_tally, admin);
    // ACL on _tally:
    //   contract: uses in subsequent ops
    //   admin: decrypts the aggregate off-chain
    //   everyone else: cannot read (including msg.sender, who contributed)
}
```

Two separate handles. Two separate ACL grants. Two separate sets of authorized readers. The voter can prove they contributed by decrypting their own per-voter handle; the aggregate stays confidential except to the admin.

This pattern generalizes beyond voting: auctions (per-bidder bid storage + winning-bid revealed), polls (per-respondent answer + aggregated counts), collaborative computation (per-contributor input + final result). Whenever multiple parties contribute to a private aggregate, this is the structure.

### 4.3 Decision rule for any new function

Before writing any `FHE.allow(handle, address)` line, ask:

1. **What does this address need to read?** State the intended capability in one sentence.
2. **Does this handle contain only what they should read, or does it contain other parties' contributions too?**
3. **If the handle contains other parties' contributions, refactor: produce a per-party handle for the per-party view, and grant only the aggregate's authorized reader (typically a privileged role like admin) on the aggregate.**

A grant line that doesn't survive this audit is presumed wrong.

---

## 5. Cross-contract ACL  [grep-verified for syntactic surface; compile-verified 2026-04-19 for transient-grant pattern via E2/E6; behavioral claims reasoned]

When `FHE.allow(handle, contractAddress)` is called with a contract address, the library treats the contract address the same as an EOA at the syntactic level — there is no library-level distinction. The function signature is `allow(handle, address)` regardless.

Behaviorally, what a contract can do with a granted handle is more restricted than what an EOA can do:

- **Reading via the relayer SDK is an off-chain operation.** EOAs have private keys and can sign EIP-712 messages to authenticate the user-decryption flow. Contracts have no private key in the same sense, so the standard user-decryption flow does not apply directly.
- **Contracts can use the handle in their own FHE operations.** A grant gives the contract the right to call `FHE.add`, `FHE.select`, etc. on the handle. This is the primary use case for cross-contract grants — passing encrypted state to a helper contract for further processing.
- **Public decryption via `FHE.makePubliclyDecryptable` is the cross-contract reveal pattern.** When a contract needs to expose a handle's plaintext to another contract (or to anyone), the path is to mark the handle publicly decryptable; off-chain code (typically the calling contract's frontend or a relayer) decrypts and submits the plaintext back on-chain.

```solidity
// Cross-contract handoff for further FHE computation:
function delegateProcessing(externalEuint32 enc, bytes calldata proof, address helper) external {
    euint32 value = FHE.fromExternal(enc, proof);
    FHE.allowTransient(value, helper);
    IHelper(helper).processEncrypted(value);
    // ACL on value during this tx:
    //   contract: uses (auto-granted by fromExternal)
    //   helper: uses for this transaction only
    //   everyone else: cannot read
}
```

The transient grant is the right pattern here — the helper contract needs ACL only for the duration of the call. Using `allow` (persistent) instead would accumulate grants over time with no way to revoke.

**What's `[reasoned]` here vs `[grep-verified]`:** the function signature is grep-verified — `FHE.allow` accepts any `address`, no EOA/contract distinction. The behavioral claims about what a granted contract can do are reasoned from the structure of the relayer SDK and decryption flows. A test using two coordinated contracts to verify the actual semantics is a candidate follow-up; not blocking for v0.1.

---

## 6. View functions  [grep-verified; compile-verified 2026-04-19 via E5]

```solidity
function isSenderAllowed(handle) view returns (bool);
function isAllowed(handle, address) view returns (bool);
```

Both pure queries against the ACL. `isSenderAllowed` checks whether `msg.sender` has ACL on the handle; `isAllowed` checks an arbitrary address.

**Use case — accepting handles from untrusted sources.** When a contract receives a handle as a parameter (e.g., from another contract's call), `isSenderAllowed` verifies the caller was authorized to pass that handle in. Without this check, an attacker could pass arbitrary handles they don't own and have the contract operate on them.

```solidity
function processExternalHandle(euint32 handle) external {
    require(FHE.isSenderAllowed(handle), "caller not authorized for this handle");
    // safe to use handle now — caller had ACL on it before passing
    _balance = FHE.add(_balance, handle);
    FHE.allowThis(_balance);
    FHE.allow(_balance, owner);
    // ACL on _balance:
    //   contract: uses in subsequent ops
    //   owner: decrypts off-chain
    //   everyone else: cannot read
}
```

**Do not use these on the contract's own state.** ACL on `_balance` is set by the contract; the contract has no need to query its own grants. Use `isSenderAllowed`/`isAllowed` only when the handle's provenance is uncertain.

---

## 7. What this file does not cover

- **Grant lifetime across `selfdestruct` or contract upgrades.** ACL is stored at the coprocessor level; the implications of contract destruction or proxy upgrade on existing grants are unverified by this skill.
- **Quantitative ACL costs.** Each grant has an HCU and gas cost; specific numbers are documented in Zama's HCU cost tables (see `references/operations.md` §4).
- **The full delegation surface.** §3.3 names that user-decryption delegation exists and is revocable; the API for granting delegation, the relayer-side flow, and use cases are deferred to `references/decryption.md` if and when that file covers it.
- **Deny-list semantics.** §3.4 names existence; surface deferred.

---

## Cross-references

- The handle-mutation rule that drives every ACL decision → `references/core-rules.md` §CR-1
- ACL re-grants in the context of operation composition → `references/operations.md` §2 (every example notes ACL re-grants)
- The per-voter/aggregate pattern as a refused anti-pattern → `references/anti-patterns.md` §4.2
- Off-chain decryption flows (public, user, delegated) → `references/decryption.md` (when drafted)
