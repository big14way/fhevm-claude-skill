# Testing FHEVM contracts

Version stamp: this file targets `@fhevm/hardhat-plugin ≥0.4.2` running against `@fhevm/solidity ≥0.10`.

This file covers writing tests for FHEVM contracts using the `@fhevm/hardhat-plugin` mock-mode runtime. The plugin is the canonical path for unit testing FHEVM logic in Hardhat — it wires `@fhevm/mock-utils` into the Hardhat lifecycle and exposes a `fhevm` runtime helper that mirrors the live coprocessor's surface without requiring a network connection.

```
§1  When mock-mode testing is the right tool
§2  The fhevm runtime helper — surface and conventions
§3  Encrypted input creation in tests
§4  Decryption assertions — return-type discipline
§5  Mock-mode-specific gotchas
§6  When mock-mode is wrong — paths to live testing
§7  What this file does not cover
```

---

## §1 — When mock-mode testing is the right tool

The plugin is the **mock path**. It runs FHEVM contract logic inside Hardhat's local EVM, with `@fhevm/mock-utils` simulating the coprocessor's encrypt/decrypt operations in-memory. Tests run fast (milliseconds per assertion), deterministically (no network), and locally (no relayer connection required).

**Use mock mode for:**

- Unit testing contract logic — ACL grants, op composition, conditional flows, error paths.
- Integration testing within a single contract or a small set of coordinated contracts.
- Continuous integration — the plugin runs in CI without network access or coprocessor credentials.
- Iterating during development — fast feedback loops on code changes.

**Mock mode does not exercise:**

- Live coprocessor cryptography. Mock-mode encryption is functional simulation, not real FHE.
- Relayer HTTP endpoints. Tests do not hit `userDecryptUrl` or `publicDecryptUrl`.
- Real EIP-712 signature verification by a remote KMS. The mock helpers accept signatures structurally without remote verification.
- Network-level concerns — gas at production rates, transaction ordering across blocks, real chain reorgs.

If a test's purpose is to exercise any of those, mock mode is wrong and the path is live testing (see §6).

---

## §2 — The `fhevm` runtime helper — surface and conventions

The plugin exposes a `fhevm` object on the Hardhat runtime environment. Import it from Hardhat's runtime:

```typescript
import { fhevm } from "hardhat";
```

The helper exposes input creation, decryption helpers per type, defensive checks, and a debugger surface.

### §2.1 — Mock-mode signal: `fhevm.isMock`  [reasoned from lived test patterns]

`fhevm.isMock` reports whether the helper is operating in mock mode. The canonical use is to skip tests that don't apply outside mock:

```typescript
it("decrypts user-decrypt result correctly", async function () {
    if (!fhevm.isMock) {
        this.skip();
        return;
    }
    // ... test body using mock-only helpers
});
```

Tests that exercise live coprocessor behavior should not run in mock mode (they will pass spuriously because the mock satisfies their assertions without testing the real cryptographic path). Tests that exercise mock-only helpers should not run in live mode (they will fail because the helpers may behave differently or not exist). The `isMock` gate keeps the same test file usable in both contexts.

### §2.2 — Defensive setup check: `assertCoprocessorInitialized`  [grep-verified]

```typescript
await fhevm.assertCoprocessorInitialized(contract, contractName?);
```

Verifies that the FHEVM coprocessor configuration has been initialized in the contract — typically by inheriting `ZamaEthereumConfig` or `ZamaSepoliaConfig` and having the constructor run. A contract deployed without proper configuration silently fails on FHE operations; this assertion turns that into a clear setup error.

Useful in test setup blocks where contract deployment is non-trivial:

```typescript
describe("ConfidentialCounter", function () {
    let contract: ConfidentialCounter;

    beforeEach(async function () {
        contract = await deploy();
        await fhevm.assertCoprocessorInitialized(contract, "ConfidentialCounter");
    });

    // tests follow
});
```

For simple deployments the check is optional — if the contract's constructor runs without errors, coprocessor configuration is typically fine. The assertion earns its keep when deployment is conditional, when contracts are upgraded via proxy, or when test failures point at suspected coprocessor-config issues.

### §2.3 — Debugger surface: `fhevm.debugger`  [grep-verified]

The `fhevm.debugger` property exists and exposes a typed `HardhatFhevmRuntimeDebugger` interface for inspecting mock-coprocessor state during a test. This skill does not document its surface in v0.1. If an agent encounters `fhevm.debugger` in test code, treat it as a real symbol whose API is outside this skill's verified scope and consult the plugin's docs.

---

## §3 — Encrypted input creation in tests

Tests create encrypted inputs via `fhevm.createEncryptedInput(contractAddress, userAddress)`. The surface and binding rules are documented in `references/input-proofs.md` §1.1 — this section covers test-specific patterns.

```typescript
const enc = await fhevm
    .createEncryptedInput(await contract.getAddress(), alice.address)
    .add32(42n)
    .encrypt();

await contract.connect(alice).setValue(enc.handles[0], enc.inputProof);
```

Three test-specific conventions:

1. **Use `alice.address`, not `await alice.getAddress()`, when the signer's address is needed for binding.** Both work; the property access is shorter and idiomatic in test code.
2. **Always `await` the chain.** The `.encrypt()` call is async — `createEncryptedInput(...).add32(...).encrypt()` returns a promise. Forgetting the await results in an unencrypted promise object being passed to the contract, producing confusing errors.
3. **Pack multiple values into one input where possible.** See `references/input-proofs.md` §1.1 — applies in tests too. Reduces test setup overhead.

---

## §4 — Decryption assertions — return-type discipline  [grep-verified]

This is the most common source of confusing test failures. **The decryption helpers do not return uniform types. An assertion that mismatches the helper's return type fails with a misleading error.**

### §4.1 — The return-type table

| Helper | Return type | Assertion shape |
|---|---|---|
| `fhevm.userDecryptEbool(handle, contract, user)` | `boolean` | `expect(x).to.eq(true)` |
| `fhevm.publicDecryptEbool(handle)` | `boolean` | `expect(x).to.eq(true)` |
| `fhevm.userDecryptEuint(type, handle, contract, user)` | `bigint` | `expect(x).to.eq(5n)` |
| `fhevm.publicDecryptEuint(type, handle)` | `bigint` | `expect(x).to.eq(5n)` |
| `fhevm.userDecryptEaddress(handle, contract, user)` | `string` (hex) | `expect(x).to.eq(addr)` |
| `fhevm.publicDecryptEaddress(handle)` | `string` (hex) | `expect(x).to.eq(addr)` |

The bigint return on the `*DecryptEuint` family is the trap; the boolean and string returns from the other helpers behave as a JavaScript developer would expect.

### §4.2 — The bigint trap

When the helper returns a `bigint` and the assertion compares against a `number` literal, chai's `.eq` reports a confusing mismatch:

```typescript
const value = await fhevm.userDecryptEuint(FhevmType.euint32, handle, contractAddr, alice.address);
expect(value).to.eq(5);     // FAILS: AssertionError: expected 5n to equal 5
```

The mock returns `5n` (bigint); the assertion compares against `5` (number); chai's strict equality treats them as distinct. Fix:

```typescript
expect(value).to.eq(5n);    // PASSES
```

This is the bigint-vs-number assertion mismatch documented in FOOTGUN_LOG. The same pattern applies to ethers.js v6 return values for `uint*` types — any time a function returns "an integer," verify whether the type is `bigint` or `number` before writing the assertion.

### §4.3 — Boolean and address assertions

`*DecryptEbool` returns native `boolean`:

```typescript
const flag = await fhevm.userDecryptEbool(handle, contractAddr, alice.address);
expect(flag).to.eq(true);    // works — no bigint involved
```

`*DecryptEaddress` returns a checksummed hex string:

```typescript
const addr = await fhevm.userDecryptEaddress(handle, contractAddr, alice.address);
expect(addr).to.eq(bob.address);    // string comparison; case-sensitive
```

If address case might differ (one source checksummed, the other lowercase), normalize with `.toLowerCase()` on both sides or use ethers.js's `getAddress()` for canonical form.

### §4.4 — Type-tag arguments to the Euint helpers

`userDecryptEuint` and `publicDecryptEuint` take a type tag as the first argument:

```typescript
import { FhevmType } from "@fhevm/hardhat-plugin/types";

await fhevm.userDecryptEuint(FhevmType.euint32, handle, contractAddr, alice.address);
await fhevm.publicDecryptEuint(FhevmType.euint64, handle);
```

Match the type tag to the handle's actual type. The signature tag does not exist on `*DecryptEbool` or `*DecryptEaddress` because those types have only one width.

---

## §5 — Mock-mode-specific gotchas

### §5.1 — `Promise.all` races the mock-coprocessor cursor  [grep-verified — FOOTGUN_LOG entry dated 2026-04-17]

Awaiting decryption helpers in parallel via `Promise.all` produces non-deterministic failures:

```typescript
// FAILS INTERMITTENTLY
const [a, b] = await Promise.all([
    fhevm.userDecryptEuint(FhevmType.euint32, handleA, contract, user),
    fhevm.userDecryptEuint(FhevmType.euint32, handleB, contract, user),
]);
```

The mock coprocessor maintains an internal cursor that advances synchronously as decryption requests are processed. Concurrent requests race the cursor, producing the wrong handle's plaintext or an internal state error. Fix: sequential awaits:

```typescript
// PASSES
const a = await fhevm.userDecryptEuint(FhevmType.euint32, handleA, contract, user);
const b = await fhevm.userDecryptEuint(FhevmType.euint32, handleB, contract, user);
```

This is mock-only behavior — the live coprocessor handles concurrent requests differently — but every test using the plugin must follow the sequential pattern. CR-3 (sequential awaits on decrypts) in `references/core-rules.md` is the rule's source. See FOOTGUN_LOG entry dated 2026-04-17 for the original error string and full mechanism.

### §5.2 — Reverts and revert reasons

Use `expect(...).to.be.reverted` for the basic case. For contract-defined custom errors, use `expect(...).to.be.revertedWithCustomError(contract, "ErrorName")`. Reverts originating inside FHE library calls may surface with library-internal messages — test for the revert; don't over-specify the reason unless the error is a custom error the contract itself defined.

---

## §6 — When mock-mode is wrong — paths to live testing

The plugin is the mock path. Live testing — exercising the real coprocessor, the relayer's HTTP endpoints, and real EIP-712 verification — does not use the plugin's `fhevm` helper. Live testing uses ethers.js (or viem) directly to interact with deployed contracts and the relayer SDK (`@zama-fhe/relayer-sdk`) for encryption and decryption.

Three cases where live testing is required:

- **Pre-deployment validation against a testnet (typically Sepolia).** Mock mode cannot catch issues that arise from real coprocessor cryptography, real relayer authentication, or real network conditions.
- **End-to-end demos.** The submission demo video (Phase 3) exercises live behavior; mock mode would not be a credible demonstration.
- **Reproducing a production bug.** If a deployed contract behaves unexpectedly, reproducing the issue against the same network is the diagnostic path.

For most development work, including the work documented in this skill's reference contracts, mock mode is the right default. Live testing is a deployment-readiness step, not a development loop.

This file does not document live testing patterns. See `references/frontend-integration.md` for relayer SDK setup and `references/decryption.md` for the user-decryption flow that live tests would exercise.

---

## §7 — What this file does not cover

- **The `fhevm.debugger` API.** Exists and is typed; surface deferred. Consult the plugin's docs if needed.
- **`@fhevm/mock-utils` direct usage.** The plugin wraps mock-utils; tests should use the plugin's `fhevm` helper, not mock-utils directly.
- **Hardhat fixtures and snapshots for FHEVM state.** Standard `loadFixture` works for contract state; coprocessor-side state interactions with snapshot/restore are not documented in this skill.
- **Testing across multiple Hardhat networks in one test run.** Mock-mode is single-network by design.
- **Live coprocessor testing patterns.** See §6 — live testing uses ethers.js + relayer SDK directly, not the plugin.
- **Performance benchmarking of FHE operations.** Mock-mode timings do not reflect live HCU costs; benchmarking requires live runs.

---

## Cross-references

- The encrypted-input round-trip (frontend and test side) — `references/input-proofs.md` §1
- Decryption flows (public, user, delegated) — `references/decryption.md`
- The CR-3 sequential-await rule — `references/core-rules.md`
- The Promise.all race original report — `FOOTGUN_LOG.md` (entry dated 2026-04-17)
- The bigint trap original report — `FOOTGUN_LOG.md` (entry dated 2026-04-17)
- Diagnostic surface for test failures — `references/troubleshooting.md` (when drafted)
