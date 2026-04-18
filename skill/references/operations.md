# Operations on encrypted values — composition patterns and rules

Version stamp: this file targets `@fhevm/solidity ≥0.10`, `encrypted-types ≥0.0.4`.

This file covers **how** to use FHE operations — the composition patterns, idioms, and cross-cutting rules that govern them. For the matrix of which ops exist on which types, see `references/encrypted-types.md` §2. For refused patterns (like `if (ebool)`), see `references/anti-patterns.md` §4.1.

Every operation on this page returns a new handle with zero ACL. Per CR-1, re-grant ACL on the result to every address that should read it. The ACL boilerplate is omitted from most examples below for clarity; in real code, it is not optional.

---

## 1. Cross-cutting rules

### 1.1 Cross-type arithmetic returns the larger type  [grep-verified; compile-verified 2026-04-19]

Binary operations between different unsigned-integer widths return the wider type. No manual upcast is needed.

```solidity
euint8 a = FHE.asEuint8(5);
euint16 b = FHE.asEuint16(300);
euint16 sum = FHE.add(a, b);  // returns euint16, the wider of the two
```

This applies to `add`, `sub`, `mul`, `min`, `max`, and the bitwise ops (`and`, `or`, `xor`). The library declares every valid cross-type pair; calling a pair that doesn't exist (e.g., mixing a usable type with an orphan type like `euint40`) fails at Solidity compile time.

**Implication:** an agent writing code that combines `euint*` values of different widths does not need to call `FHE.asEuintXX` to promote operands before the operation. The cast pattern is appropriate only when constructing a fresh encrypted value, not when conforming operand widths.

### 1.2 Plaintext operands on either side — for most ops  [grep-verified; compile-verified 2026-04-19]

`add`, `sub`, `mul`, `min`, `max`, and the bitwise ops accept a plaintext operand on either side:

```solidity
// All three forms are valid:
euint32 a = FHE.add(_balance, amount);          // both encrypted
euint32 b = FHE.add(_balance, 5);                // plaintext right
euint32 c = FHE.add(5, _balance);                // plaintext left
```

The plaintext operand's width must match the encrypted operand's width — `FHE.add(_euint32, 5)` works because `5` fits in `uint32`; `FHE.add(_euint8, uint16Value)` does not compile. Same-width plaintexts only.

**Comparison ops accept plaintext-right-side operands for the full usable width range:**

```solidity
ebool large = FHE.gt(_balance, 1000);            // plaintext right — no wrapping needed
ebool small = FHE.le(_balance, threshold);       // encrypted right — also fine
```

`eq`, `ne`, `lt`, `le`, `gt`, `ge` all have `(euintXX, uintXX)` overloads. This is the common case an agent reaches for — comparing an encrypted value against a known threshold.

Plaintext-*left*-side comparisons (`FHE.gt(1000, _balance)`) are not confirmed by grep in this file. If the code calls for that shape, grep `FHE.sol` for `function gt(uint32` (or the relevant width) before relying on it. The shape is unusual enough in practice that agents should reach for the right-side form by default.

**Asymmetry worth remembering: `div` and `rem` are plaintext-right only.**

```solidity
euint32 quotient = FHE.div(_balance, 2);         // OK — encrypted / plaintext
euint32 wrong = FHE.div(100, _balance);          // does not compile
```

Division by an encrypted value is not in the library at all, in either direction. The one-sided `div(euint, uint)` is not asymmetric by oversight — it's the library's full surface for division. See §3.4.

### 1.3 `ebool` is the control type for everything  [grep-verified]

Every `FHE.select(cond, a, b)` takes `ebool` as its first argument, regardless of the types of `a` and `b`. Predicates produced by comparison ops (`eq`, `ne`, `lt`, etc.) return `ebool` and feed directly into `select`.

```solidity
ebool isLarge = FHE.gt(_balance, 1000);
euint32 result = FHE.select(isLarge, _balance, FHE.asEuint32(0));
```

This is the only branching construct available — plaintext `if` on an encrypted value is impossible (see `anti-patterns.md` §4.1).

### 1.4 Shifts accept encrypted or plaintext shift amount  [grep-verified]

```solidity
euint32 a = FHE.shl(_value, 3);                  // plaintext shift — cheap
euint32 b = FHE.shl(_value, _secretShift);       // encrypted shift — private
```

Use plaintext shifts when the shift amount is public (cheaper). Use encrypted shifts only when the shift amount itself is secret data. Both are supported.

---

## 2. Composition idioms

These are multi-op patterns that come up repeatedly in FHEVM contracts. Each has at least one non-obvious detail that agents reasoning from Solidity intuition will get wrong.

### 2.1 Accumulate a count over a condition  [grep-verified for cast signature; compile-verified 2026-04-19 via E3]

Incrementing a counter every time a predicate is true.

**Naive (works, but verbose):**

```solidity
ebool cond = FHE.gt(amount, threshold);
_count = FHE.add(_count, FHE.select(cond, FHE.asEuint8(1), FHE.asEuint8(0)));
```

**Idiomatic (library supports direct cast from `ebool` to `euintXX`):**

```solidity
ebool cond = FHE.gt(amount, threshold);
_count = FHE.add(_count, FHE.asEuint8(cond));  // ebool → 0 or 1 directly
```

The direct `FHE.asEuint8(ebool)` cast is declared in the library for all standard widths. This avoids a `select` and a trivial encryption on each branch — both pure overhead.

Remember CR-1: `_count` after `FHE.add` is a new handle. Re-grant ACL on it.

### 2.2 Clamp to a plaintext ceiling  [grep-verified; compile-verified 2026-04-19 via E4]

Bounding an encrypted value by a public maximum, without encrypting the maximum.

```solidity
euint32 capped = FHE.min(_amount, 1000);  // plaintext ceiling on right side
```

No need for `FHE.asEuint32(1000)` — the plaintext-side overload of `min` handles it. Same for plaintext floor via `FHE.max(_amount, minimum)`.

This pattern is common for enforcing protocol limits that are public by design (maximum transaction size, minimum stake) on values that are private.

### 2.3 Branchless conditional update  [grep-verified for signatures; compile-verified 2026-04-19 via E5; mechanism reasoned]

Updating encrypted state only when a condition holds, without revealing whether the update happened.

```solidity
ebool shouldUpdate = FHE.gt(newValue, _currentValue);
_currentValue = FHE.select(shouldUpdate, newValue, _currentValue);
FHE.allowThis(_currentValue);
FHE.allow(_currentValue, authorizedReader);
```

Two details agents get wrong:

1. The `else` branch is `_currentValue`, not a default. When the condition is false, the state stays the same — but a *new handle* is still produced. The ACL re-grant applies regardless of which branch was semantically taken; the coprocessor does not know which branch was chosen, and neither does the contract.
2. The chosen-ness of the branch does not leak through gas. Both branches' setup ops always execute — Solidity is eagerly evaluated, so the two arguments to `select` exist as already-computed handles before the `select` call runs. The `select` itself is a ciphertext mux with constant cost regardless of `shouldUpdate`'s plaintext value. The combination — eager argument evaluation plus constant-cost mux — is what gives the confidentiality-preserving property.

### 2.4 Comparison chain feeding a select  [grep-verified for signatures; compile-verified 2026-04-19 via E6]

Combining multiple encrypted comparisons into a single conditional choice.

```solidity
ebool inRange = FHE.and(
    FHE.ge(amount, 10),
    FHE.le(amount, 1000)
);
euint32 output = FHE.select(inRange, amount, FHE.asEuint32(0));
```

`FHE.and(ebool, ebool)` returns `ebool` and can chain arbitrarily. `or` and `xor` work the same way. For more than two conditions, chain:

```solidity
ebool allOk = FHE.and(FHE.and(condA, condB), condC);
```

Note the plaintext-right-side bounds (`10`, `1000`) — no `FHE.asEuint32` wrapping is needed per §1.2. The trailing `FHE.asEuint32(0)` in the `select` *is* needed because both branches of `select` must be the same encrypted type, and there's no plaintext-branch overload.

No short-circuit evaluation exists — every sub-predicate is always computed. This is not a performance optimization opportunity; it is a confidentiality property.

### 2.5 Sum-then-cap  [reasoned]

Accumulating a sum and enforcing a plaintext maximum in one logical step.

```solidity
_balance = FHE.min(FHE.add(_balance, deposit), PLAINTEXT_CEILING);
FHE.allowThis(_balance);
FHE.allow(_balance, depositor);
```

Note the two ops produce two new handles — the intermediate `FHE.add` result and the final `FHE.min` result. Only the final handle needs ACL re-grants; the intermediate is ephemeral and its ACL is irrelevant.

This pattern avoids overflow-into-silent-wraparound (FHE arithmetic wraps on overflow with no revert — it cannot revert without leaking). Capping via `min` with a known-safe plaintext keeps the result in a valid range by construction.

---

## 3. Operation categories — what exists, what doesn't, why

This section is a prose companion to the matrix in `encrypted-types.md` §2, focused on *why* certain gaps exist rather than simply enumerating them.

### 3.1 Arithmetic — standard on `euint8`–`euint128`, absent on `euint256`/`eaddress`/`ebool`  [grep-verified]

`add`, `sub`, `mul`, `neg`, `min`, `max` are declared for every pair in `euint8`–`euint128` (including cross-width and plaintext-either-side variants). `euint256` has no binary arithmetic — use it only for hash-shaped opaque values or bitfields. `eaddress` and `ebool` have no arithmetic by design.

`sub` on unsigned types wraps on underflow (same behavior as plaintext `uint` arithmetic, but without any way to check or revert). For subtraction that must not underflow, use **saturating subtraction** (also called *monus*): `FHE.sub(a, FHE.min(a, b))`. The result is zero when `b > a` and `a - b` otherwise, never a wrapped large value.

### 3.2 Comparison — full on `euint8`–`euint128`, equality-only on `euint256`/`eaddress`  [grep-verified]

`eq` and `ne` exist for every usable type including `euint256` and `eaddress`. Ordering (`lt`, `le`, `gt`, `ge`) exists only for `euint8`–`euint128`.

`euint256` equality is useful for hash comparisons ("does this encrypted hash equal this expected value?") — the absence of ordering on `euint256` is not a general limitation of the library but a type-specific gap. `eaddress` ordering is impossible in v0.11.1 and has no workaround; see `encrypted-types.md` §4.2.

All comparison ops return `ebool`, which feeds into `select` (§1.3) or logical ops (§2.4).

### 3.3 Bitwise and shifts  [grep-verified]

`and`, `or`, `xor`, `not`, `shl`, `shr` are declared broadly. Notably `euint256` *does* have bitwise and shift support (one of the few op categories where it's not an exception). This is why `euint256` is the right type for bitfield-style storage despite having no arithmetic.

### 3.4 Division — plaintext divisor only  [grep-verified]

`FHE.div(euintXX, uintXX)` exists; `FHE.div(uintXX, euintXX)` and `FHE.div(euintXX, euintXX)` do not. Same for `rem`.

**This is a constraint, not an absence.** Encrypted-by-encrypted division is not in the library at all — the cryptographic cost of homomorphic division by a secret divisor is prohibitive. An agent asked to implement "divide by a user-supplied encrypted value" should flag this to the user and ask whether the divisor can be public, or whether the design can be restructured to avoid division.

Division by a known constant (e.g., "take 10% of an encrypted balance" as `FHE.div(balance, 10)`) is fully supported and cheap.

### 3.5 Casts  [grep-verified]

`FHE.asEuintXX(plaintext)` trivially encrypts a plaintext. `FHE.asEuintXX(ebool)` converts boolean 0/1 to an encrypted integer (see §2.1). Cross-width `euint` casts exist for promotion and truncation between standard widths.

`FHE.asEaddress(plaintext)` exists. `FHE.asEbool(plaintext)` exists. Casts to or from the orphan type families (signed, 8-bit-increment widths, byte arrays) are not declared — consistent with those families having no ops (see `encrypted-types.md` §5).

### 3.6 Randomness  [grep-verified]

`FHE.randEuintXX()` generates a random encrypted value in the full type range. `FHE.randEuintXX(upperBound)` generates a random value in `[0, upperBound)`. Both are declared for `ebool`, every standard unsigned width, and `euint256`.

No `randEaddress`. Randomness on encrypted addresses is not a supported operation — if an agent needs a random address, generate plaintext-side and encrypt via `FHE.asEaddress`.

The security characteristics of `FHE.randEuintXX` for high-stakes use (lotteries, security-critical nonces, anything where adversarial commitment matters) are outside this skill's verified scope. Consult Zama's cryptography documentation before relying on coprocessor randomness for high-stakes applications.

---

## 4. HCU — homomorphic compute budget  [reasoned]

Every FHE operation consumes **homomorphic compute units** (HCU). HCU cost is not EVM gas; it is a separate budget tracked by the coprocessor and charged at transaction-submission time. A transaction that exceeds the HCU limit reverts with an HCU-specific error.

**What an agent must know:**

- HCU cost scales roughly with operand bit-width. `FHE.add(euint8, euint8)` is cheaper than `FHE.add(euint64, euint64)`. Choose the smallest type that fits the range (see `encrypted-types.md` §1). [reasoned from docs]
- Loops over encrypted state are the most common way to blow the budget. A function that iterates over an array of encrypted balances and does arithmetic on each element can exhaust HCU in a handful of iterations. Design for fixed-size or bounded patterns. [reasoned]
- Specific numeric limits (HCU per transaction, HCU per op by type) change across library versions and are documented in the Zama docs. This skill does not quote specific numbers because they go stale. When HCU becomes relevant for a specific contract, consult the current docs. [reasoned]

**What an agent should not do:**

- Assume FHE ops are priced like EVM ops. They aren't. An EVM opcode costs ~3-100 gas; an FHE op can cost millions of HCU. Order-of-magnitude different.
- Micro-optimize individual ops based on HCU intuition. Choose types correctly, avoid loops over encrypted state, and trust the library's implementations.
- Treat HCU exhaustion as a runtime bug. It's a design issue — the function shape is wrong for FHE, not the implementation.

Specific scaling factors (per op, per type-pair) are documented in Zama's HCU cost tables — consult docs for transaction-level budget planning.

HCU is a concept where "see the docs for current limits" is the right answer. The rule is the rule; the numbers are version-specific.

---

## 5. What this file does not cover

- **Access control for op results.** Every op produces a new handle with zero ACL. See CR-1 and `references/access-control.md`.
- **Input proofs and `FHE.fromExternal`.** This is how encrypted values enter the contract in the first place — a distinct concern from what you do with them once they're inside. See `references/input-proofs.md`.
- **Decryption of op results.** Public vs. user decryption patterns. See `references/decryption.md`.
- **Specific HCU numbers.** Per §4, consult Zama docs.
- **Orphan types.** If you're reading this file and wondering about `euint160` or `eint32`, see `encrypted-types.md` §5 — none of these types have ops.
