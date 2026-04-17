# Encrypted types — decision guide and reference

Version stamp: this file targets `@fhevm/solidity ≥0.10`, `encrypted-types ≥0.0.4`.

Encrypted types are declared in `encrypted-types/EncryptedTypes.sol`, not in `@fhevm/solidity/lib/FHE.sol`. See `anti-patterns.md` entry 2.1 for the layout footgun. For the full inventory of declared types, grep `node_modules/encrypted-types/EncryptedTypes.sol`. This file covers the canonical subset an agent should actually use.

---

## Decision table — which type to use

Pick the smallest type that fits your value range and supports the operations you need. Smaller types are cheaper in homomorphic compute units (HCU) and in gas. Defaulting to `euint256` "to be safe" is the most common type-selection mistake — see §4.

| Use case | Type | Range | Rationale |
|---|---|---|---|
| Encrypted flag, vote, boolean result | `ebool` | 0 or 1 | Smallest; all logical ops supported |
| Small counter, age, vote weight | `euint8` | 0 – 255 | Smallest integer; full arithmetic |
| Rating, percentage, small index | `euint16` | 0 – 65,535 | Full arithmetic |
| Application-level quantity, bid amount, nonce | `euint32` | 0 – ~4.3B | Full arithmetic; default choice for most counters  [mock-verified 2026-04-17] |
| Token balance, price, large quantity | `euint64` | 0 – ~1.8×10¹⁹ | Full arithmetic; covers most financial ranges |
| Oversized balance, rare values | `euint128` | up to 2¹²⁸ − 1 | Full arithmetic; use only when `euint64` is insufficient |
| Hash, address-shaped data | `eaddress` | 160 bits | Equality and `select` only — no ordering, no arithmetic |
| 256-bit bitfield, hash storage (opaque) | `euint256` | up to 2²⁵⁶ − 1 | Bitwise + equality only — **no binary arithmetic** (see §4) |
| User-encrypted input from frontend | `externalEuint*` | matches target type | Must be converted via `FHE.fromExternal` before use |

**Default choice for new work: `euint32`.** Covers the range needed by counters, small tallies, vote weights, indices, and most application quantities. All arithmetic operations are supported. Upgrade to `euint64` only when the value range demands it. Downgrade to `euint8`/`euint16` for constrained ranges — smaller types cost less in homomorphic compute and gas; see `references/operations.md` on HCU budget when that file is drafted.

---

## Operation support matrix

Every type supports a different subset of operations. Calling an unsupported operation on a type fails at Solidity compile time with an unresolved-function error. Not every declared type has operations wired at all — see §5 on orphan type declarations.

| Operation | `ebool` | `euint8-128` | `euint256` | `eaddress` |
|---|---|---|---|---|
| `add`, `sub`, `mul` | — | ✓ | ✗ | ✗ |
| `div`, `rem` (plaintext divisor) | — | ✓ | ✗ | ✗ |
| `min`, `max` | — | ✓ | ✗ | ✗ |
| `and`, `or`, `xor` | ✓ | ✓ | ✓ | ✗ |
| `not` | ✓ | ✓ | ✓ | ✗ |
| `shl`, `shr` | — | ✓ | ✓ | ✗ |
| `eq`, `ne` | ✓ | ✓ | ✓ | ✓ |
| `lt`, `le`, `gt`, `ge` | — | ✓ | ✗ | ✗ |
| `neg` | — | ✓ | ✓ | ✗ |
| `select(cond, a, b)` | ✓ | ✓ | ✓ | ✓ |
| `rand`, `randBounded` | ✓ | ✓ | ✓ | ✗ |

[mock-verified 2026-04-18 — `euint32` full row verified in Counter/Vote contracts; `euint256` row verified by grep against `FHE.sol` (including corrections for `neg` at FHE.sol:8471 and `randEuint256` at FHE.sol:8781/8789); `ebool`, `euint8-128` family, `eaddress` verified by grep for all listed ops]

**Key gaps to remember:**

- `euint256` has **no binary arithmetic** — no `add`, `sub`, `mul`, `div`, `rem`, `min`, `max`. It has no ordering comparisons (`lt`/`le`/`gt`/`ge`). It *does* have `neg` (unary negation), `rand`, `randBounded`, all bitwise ops, shifts, equality, and `select`. Use for bitfields, hash-shaped opaque 256-bit values, or cases where equality is the only meaningful operation.
- `eaddress` has **no ordering and no bitwise** — only equality (`eq`/`ne`) and `select`. Treat it as an opaque identifier, not a value with operations. See §4.2 on why ordering on encrypted addresses has no library-supported solution.
- `ebool` has **no arithmetic or ordering** — only logical ops and `select`. It is a result type, not a counter.
- `div` and `rem` on `euint*` types accept only a **plaintext divisor** (a `uint32` literal or variable), not an encrypted one. Dividing by an encrypted value is not supported.

---

## External input types

Every `euint*`, `ebool`, `eaddress` has a matching `externalEuint*`, `externalEbool`, `externalEaddress`. These are the types used in function parameters when the caller passes an encrypted input from the frontend:

```solidity
function increment(externalEuint32 encAmount, bytes calldata inputProof) external {
    euint32 amount = FHE.fromExternal(encAmount, inputProof);
    // amount is now a normal euint32, usable in FHE ops
}
```

The `externalEuint*` type is a thin wrapper around a ciphertext handle plus metadata for the input proof. It is **not directly usable in FHE operations** — it must be converted via `FHE.fromExternal(external, proof)` which verifies the proof and returns the underlying `euint*` type. See `references/input-proofs.md` for the full pattern.

Do not mix `externalEuint*` and `euint*` in computations. The compiler will reject it, but the category distinction matters for design: external types are input-boundary only.

---

## Anti-selection — common wrong choices

### 4.1 Picking `euint256` because "bigger is safer"

This is the most common type-selection mistake. `euint256` looks like `uint256` in name and bit-width, and Solidity developers default to `uint256` without thinking. In FHEVM, `euint256` has a *smaller operation surface* than the integer types that are literally smaller than it — no arithmetic, no ordering comparisons.

An agent generating a contract for "encrypted token balance" using `euint256` will write a contract that cannot add, subtract, or compare balances. The contract compiles only as long as no arithmetic is attempted; the first `FHE.add(balance, amount)` fails at Solidity compile time with an unresolved-function error.

**Fix:** use `euint64` for token balances (covers 18.4 × 10¹⁸, larger than most real-world supply requirements). Reserve `euint256` for hash storage or opaque bitfields.

### 4.2 Needing ordering on encrypted addresses

`eaddress` supports only equality and `select`. There is no library-provided path to ordering on encrypted addresses in v0.11.1: `euint160` exists as a declared type in `encrypted-types/EncryptedTypes.sol` but has **no FHE operation overloads in `@fhevm/solidity`** (verified by grep — this is the orphan-declaration class, see §5). Bit-splitting an address across multiple `euint*` fields to fake comparison is complex enough to be a design smell rather than a solution.

**Fix:** redesign the contract to not require encrypted address ordering. If an agent encounters a requirement for it ("sort participants by encrypted address," "find the smallest address in a set"), flag the limitation to the user explicitly: the current library does not support this operation. Ask whether the requirement can be restructured — for example, map addresses to `euint32` indices at registration time and order the indices.

This is the one type-selection case where the right answer is to push back on the requirement itself, not to pick a different type.

### 4.3 Using `ebool` as a counter

`ebool` is not an `euint1`. It has no arithmetic. Incrementing a boolean count requires `euint8` or larger, with the increment expressed via `FHE.add`. If the original intent was "count how many times a condition was true," use `FHE.select(cond, FHE.asEuint8(1), FHE.asEuint8(0))` to convert the ebool to a 0/1 euint, then accumulate.

**Fix:** `euint8` for counts up to 255, upgrading as needed.

---

## Orphan type declarations — declared but unusable

The `encrypted-types` package declares more types than `@fhevm/solidity` wires operations for. A type that appears in `EncryptedTypes.sol` is not necessarily usable. You can write `euint160 x;` and the file parses, but every subsequent line that tries to add, compare, allow, or operate on `x` fails at Solidity compile time with an unresolved-function error.

This is a category of hazard distinct from stale APIs and stale layouts: the type exists *now*, in the current library, but has no operational support. It is a trap for agents that grep only for type declarations and assume presence implies usability.

**Verification rule (CR-2 extension):** When considering a type not in the canonical set, grep `FHE.sol` for *at least one* `FHE.*` overload on that type. Declaration presence in `EncryptedTypes.sol` is necessary but not sufficient. No overloads means the type is an orphan — avoid.

### Verified-usable types (canonical set)

These are the types the skill teaches and tests against.

- **Unsigned integers — standard widths:** `euint8`, `euint16`, `euint32`, `euint64`, `euint128`, `euint256` (with the gaps documented in §2). [mock-verified 2026-04-18 for `euint32` and `euint64` via Counter and Vote contracts; `euint256` op coverage verified by grep]
- **Boolean:** `ebool`. [mock-verified 2026-04-17]
- **Address:** `eaddress`. [mock-verified 2026-04-17]
- **External input variants of the above:** `externalEuint8/16/32/64/128/256`, `externalEbool`, `externalEaddress`. [mock-verified 2026-04-17 for `externalEuint32` and `externalEbool`; others by analogy and grep]

### Verified-orphan types — declared but no ops

These types are declared in `encrypted-types/EncryptedTypes.sol` but have no corresponding `FHE.*` operation overloads in `@fhevm/solidity` v0.11.1. Verified by grep. **Do not use.** If a contract appears to require one of them, use the next-larger canonical type or redesign the requirement.

- **Unsigned integers — 8-bit-increment widths** (`euint24`, `euint40`, `euint48`, `euint56`, `euint72`, `euint80`, `euint88`, `euint96`, `euint104`, `euint112`, `euint120`, `euint136`, `euint144`, `euint152`, `euint160`, `euint168`–`euint248`): orphan declarations, no ops. Use the next-larger standard width (e.g., `euint64` instead of `euint40`). [mock-verified 2026-04-18 — orphan declarations, no ops]
- **Signed integers** (`eint8` through `eint256`, all widths): orphan declarations, no ops. If signed arithmetic is required, consult the Zama docs for the current state of signed support — it may arrive in a later release. [mock-verified 2026-04-18 — orphan declarations, no ops]
- **Byte arrays** (`ebytes1` through `ebytes32`): orphan declarations, no ops. See also `anti-patterns.md` entry 1.6 for the related pre-v0.7 footgun. [mock-verified 2026-04-18 — orphan declarations, no ops]

If an agent needs to work with a type not in either list above, follow the verification rule at the top of this section. Do not assume operation support.
