# Core rules — CR-1, CR-2, CR-3

These three rules are the operational core of every FHEVM task. An agent that
internalizes them will avoid the three most frequent failure modes. An agent
that does not will fail silently — with green-looking tests, compile-passing
code, and a production bug.

Version stamp: this file targets `@fhevm/solidity ≥0.10`, `@fhevm/hardhat-plugin ≥0.4`.

---

## CR-1 — Every FHE op produces a new handle with zero ACL  [mock-verified 2026-04-17]

### Statement

Every FHE operation (`FHE.add`, `FHE.sub`, `FHE.mul`, `FHE.select`, `FHE.fromExternal`, `FHE.asEuint*`, and every other `FHE.*` that returns an encrypted value) produces a **new handle**. That new handle has **zero ACL**. No address — not the contract, not the deployer, not the caller, not the previous handle's authorized readers — has permission on it until you explicitly grant.

After every op, re-grant ACL on the new handle to every address that should read the result.

### Why this matters

FHEVM's ACL is **per-handle**, not per-variable and not per-address. The Solidity `euint32 _count;` line declares a storage slot. The value in that slot is a handle — a reference to a ciphertext held by the coprocessor. ACL is attached to the handle, not to the slot. When you do `_count = FHE.add(_count, amount);`, the slot gets a *different* handle than it had before. That new handle has never existed before, so no ACL exists for it.

Standard Solidity intuition says: "if I assign `x = x + 1`, `x` still refers to the same logical variable, so its permissions don't change." This intuition is wrong for FHEVM. The variable name is stable; the handle behind it is not.

### The failure mode this prevents

Without re-granting:
- The contract can no longer operate on the new handle (missing `FHE.allowThis`). Any subsequent op inside the contract reverts with an ACL error. [mock-verified 2026-04-17]
- No external reader can decrypt the new handle. A function intended to return the value for off-chain decryption will revert for the caller, or return a handle the caller has no permission to decrypt.
- This bug frequently hides behind green tests if the test pattern happens to re-grant implicitly as a side effect of the next op. It surfaces when a function path exercised by the test fixture isn't exercised in real use.

### Correct pattern

```solidity
function increment(externalEuint32 encAmount, bytes calldata proof) external {
    euint32 amount = FHE.fromExternal(encAmount, proof);
    _count = FHE.add(_count, amount);

    // Required re-grants on the new handle:
    FHE.allowThis(_count);          // contract can use _count in future ops
    FHE.allow(_count, owner);       // owner can decrypt _count off-chain
}
```

### Incorrect pattern

```solidity
// BROKEN — ACL grants in constructor do not carry to post-op handles.
constructor() {
    _count = FHE.asEuint32(0);
    FHE.allowThis(_count);
    FHE.allow(_count, owner);
}

function increment(externalEuint32 encAmount, bytes calldata proof) external {
    euint32 amount = FHE.fromExternal(encAmount, proof);
    _count = FHE.add(_count, amount);
    // MISSING: no re-grant. owner can no longer read _count after this line.
}
```

### Conceptual sharpening: ACL follows handle production, not data contribution

A user who supplies an encrypted input to `increment` (via `FHE.fromExternal`) does **not** automatically gain ACL on the result. Intuition from standard access-control systems says "if I contributed to this value, I should be able to read it." That is not how FHEVM works. [mock-verified 2026-04-17]

The address that receives ACL on a new handle is the address the contract *explicitly grants* to. The contract is the producer of the handle (every op runs inside a contract call); it decides who reads. Contribution does not imply permission.

**Load-bearing consequence for multi-user contracts.** Writing a "voters can verify their vote was counted" flow requires **per-voter storage**:

```solidity
mapping(address => euint32) voterContribution;

function vote(externalEuint32 encWeight, bytes calldata proof) external {
    euint32 weight = FHE.fromExternal(encWeight, proof);
    voterContribution[msg.sender] = weight;
    _tally = FHE.add(_tally, weight);

    FHE.allowThis(_tally);
    FHE.allow(_tally, admin);  // only admin reads the aggregate

    FHE.allowThis(voterContribution[msg.sender]);
    FHE.allow(voterContribution[msg.sender], msg.sender);  // voter reads own contribution only
}
```

Granting `FHE.allow(_tally, msg.sender)` instead — a common mistake when generating this pattern — leaks the full running count to every voter. The fix is separate storage for each voter's own contribution, granted to that voter specifically; the aggregate tally is granted only to the address that should read the final result.

### Log-entry backing

Footgun log entries #2 (initial `allowThis` didn't grant owner on post-op handles), #8 (ACL-follows-production conceptual entry), #10 (meta-note on standard-Solidity-intuition blind spots).

---

## CR-2 — Grep the installed library before trusting any FHEVM symbol

### Statement

Before writing code that uses any FHEVM symbol — function name, type, config import, library path — that is not already present in the user's repository, grep for it in the installed library:

```bash
grep -rn "<symbol>" node_modules/@fhevm/solidity/lib/FHE.sol
grep -rn "<helper>" node_modules/@fhevm/hardhat-plugin/
```

If the symbol is not found, it does not exist in the installed version. Do not write code that calls it. Report the missing symbol to the user and ask whether to use the current-version equivalent or to update dependencies.

### Why this matters

FHEVM's API changed substantially between v0.7, v0.8, and v0.10. Symbols that were canonical in older versions have been removed, renamed, or consolidated. LLM training data overwhelmingly predates the current library; the priors are stale.

`references/anti-patterns.md` enumerates every known removal and its replacement. That list is not exhaustive — future library versions (v0.12+) will add and remove more. The grep-before-trust workflow is **version-independent**: it will catch stale priors against any future version without requiring this skill to be rewritten.

### The failure mode this prevents

Without the grep:
- Agent generates `FHE.requestDecryption(...)` based on a 2024-era blog post. Contract doesn't compile. Agent spends multiple iterations hypothesizing wrong causes (wrong imports, wrong type signatures, wrong Solidity version). [mock-verified 2026-04-17]
- Agent generates `import {SepoliaConfig} from "@fhevm/solidity/config/ZamaConfig.sol"`. Import fails. Same failure-to-diagnose loop. [mock-verified 2026-04-17]
- Agent generates `FHE.mul(euint256_a, euint256_b)` because it assumed `euint256` supports arithmetic like the smaller types. Does not compile — no such overload exists. Verified via `grep -rn 'function mul(euint256' node_modules/@fhevm/solidity/lib/FHE.sol` returning empty. `euint256` supports `and/or/xor/eq/ne/shl/shr` only; arithmetic requires `euint128` or smaller. [mock-verified 2026-04-17]

The grep resolves each of these in under a second and replaces a diagnostic guessing game with a filesystem-grounded answer.

### Correct pattern

```bash
# Before writing code using FHE.requestDecryption:
$ grep -rn "requestDecryption" node_modules/@fhevm/solidity/lib/FHE.sol
# (empty output)
# → symbol does not exist; check anti-patterns.md for replacement
```

### The automated form of this rule

`scripts/verify-env.sh` runs the full set of greps for every canonical symbol this skill relies on. Run it once at session start; it replaces individual greps for the standard symbols. Use manual greps for symbols this skill doesn't cover.

### Log-entry backing

Footgun log entries #1 (`SepoliaConfig` discovery), #6 (headline pre-v0.9 API removal), and the author's own CR-2 violation caught by `verify-env.sh` (encrypted types live in the `encrypted-types` package, not `@fhevm/solidity`).

---

## CR-3 — Serialize fhevm decrypt calls in tests with sequential await

### Statement

In Hardhat tests using `@fhevm/hardhat-plugin`, call `fhevm.publicDecryptEuint` and `fhevm.userDecryptEuint` with sequential `await` — never `Promise.all`.

### Correct

```typescript
const a = await fhevm.publicDecryptEuint(FhevmType.euint32, handleA);
const b = await fhevm.publicDecryptEuint(FhevmType.euint32, handleB);
const c = await fhevm.publicDecryptEuint(FhevmType.euint32, handleC);
expect(a).to.eq(5n);
expect(b).to.eq(10n);
expect(c).to.eq(7n);
```

### Incorrect

```typescript
// BROKEN — races the mock coprocessor's event cursor
const [a, b, c] = await Promise.all([
  fhevm.publicDecryptEuint(FhevmType.euint32, handleA),
  fhevm.publicDecryptEuint(FhevmType.euint32, handleB),
  fhevm.publicDecryptEuint(FhevmType.euint32, handleC),
]);
```

### Why this matters

The `@fhevm/hardhat-plugin` mock coprocessor tracks block events via an internal cursor (`BlockLogCursor.updateForward` in the plugin source). Concurrent decrypt calls race to advance the cursor, and the losing call fails with an internal error that points inside `node_modules` — not at the test.

This is the worst class of test flake:
- Passes on small test data (one decrypt, two decrypts with small event log)
- Fails on larger test data (three decrypts after several prior ops)
- The error message does not identify the root cause (`Parse event at blockNumber=N, logIndex=M in backward order` or similar, inside plugin internals)
- An agent debugging this error will hypothesize contract bugs — wrong ACL, wrong handle, wrong type — before suspecting the test's concurrency pattern

### The failure mode this prevents

Without the rule, an agent writing a test for a contract with multiple encrypted state variables naturally reaches for `Promise.all` (idiomatic JavaScript for independent async ops). The test passes locally on small inputs, fails on larger inputs or in CI, and the error surface points into `@fhevm/hardhat-plugin/.../BlockLogCursor` — not at the test file. Diagnosis requires reading the plugin's internal cursor logic to understand why the coprocessor state desynced, because the stack trace does not implicate the test's concurrency pattern. [mock-verified 2026-04-17]

With the rule, the agent writes sequential awaits from the start. Test passes deterministically regardless of data size. Cost: three extra lines per multi-decrypt test. No runtime penalty — the decrypts block on the mock sequentially anyway.

### Scope of the rule

- **Applies to**: `fhevm.publicDecryptEuint`, `fhevm.userDecryptEuint`, and any other `fhevm.*Decrypt*` helper the plugin exposes.
- **Does not apply to**: contract method calls (`await contract.increment(...)`), deployment awaits, `fhevm.createEncryptedInput` (this is setup, not a decrypt op).
- **Unknown**: whether the same race exists on live Sepolia. The cursor is a mock-only construct. Sequential awaits are still correct on Sepolia (they cost nothing), but the *reason* is mock-specific. [unverified — pending Phase 3 Sepolia deploy]

### Log-entry backing

Footgun log entry #9 (ConfidentialVote test 5 flake discovery).

---

## Operational summary

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

These three rules interlock: CR-2 catches stale-API generation before it reaches code; CR-1 governs all state-mutating contract code; CR-3 governs all decrypt-calling test code. Between them, they cover the three most common failure modes in FHEVM dApp development.
