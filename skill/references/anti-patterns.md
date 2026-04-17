# Anti-patterns — patterns the agent must refuse to generate

Version stamp: this file targets `@fhevm/solidity ≥0.10`, `@fhevm/hardhat-plugin ≥0.4`, `encrypted-types ≥0.0.4`.

This list is not exhaustive. Per CR-2, when encountering an unknown FHEVM symbol or layout, grep the installed library — do not guess from training-data priors. This file documents the specific stale patterns the skill's author has verified as absent in the current library (and present in training-data-era examples). Future library versions will introduce new cases; the grep-before-trust workflow is the durable catch.

Each entry below follows a fixed template:

- **Pattern to refuse** — the exact code shape
- **Why the agent will generate this** — the training-data prior being activated
- **Correct replacement** — what to write instead
- **How verify-env.sh or lint-antipatterns.js catches it** — the automated defense
- Provenance tag

---

## Section 1 — Stale API names (removed or renamed in v0.7–v0.10)

### 1.1 `FHE.requestDecryption` and gateway callbacks  [mock-verified 2026-04-17]

**Pattern to refuse:**
```solidity
// BROKEN — API removed in v0.9
uint256 requestId = FHE.requestDecryption(
    handles,
    this.onDecryptionResult.selector
);

function onDecryptionResult(uint256 requestId, uint32 plaintext, bytes[] memory signatures) public {
    FHE.checkSignatures(requestId, signatures);
    // ...
}
```

**Why the agent will generate this:** The `requestDecryption` + gateway callback pattern was idiomatic in FHEVM v0.7–v0.8 and appears in blog posts, tutorials, Stack Overflow answers, and GitHub examples dated through early 2025. Most LLM training data predates the v0.9 consolidation that removed this flow. When asked to write a contract that "reveals" an encrypted value, the pattern-match reaches for `requestDecryption` because that's what the training corpus shows.

**Correct replacement:**
```solidity
// v0.10+ public decryption flow
function reveal() external onlyAuthorized {
    FHE.makePubliclyDecryptable(_value);
    // Plaintext is now available off-chain via the relayer SDK.
    // Solidity stores the handle only; decryption happens in the frontend
    // or test code via fhevm.publicDecryptEuint.
}
```

`FHE.checkSignatures` still exists for dApps that want to accept caller-submitted signed plaintexts on-chain, but the gateway-produced callback pattern does not. See `references/decryption.md` for the full v0.10+ flow.

**Caught by:** `verify-env.sh` Check 4 greps for `requestDecryption` absence in `FHE.sol`; if present in a future library version, the script emits a WARN and this anti-pattern may need revisiting. `lint-antipatterns.js` greps user code for the exact substring `FHE.requestDecryption` and flags it.

---

### 1.2 `DecryptionOracle`, `GatewayCaller`, `onDecryptionResult`  [mock-verified 2026-04-17]

**Pattern to refuse:**
```solidity
// BROKEN — all three symbols removed in v0.9
import "@fhevm/solidity/gateway/DecryptionOracle.sol";

contract MyContract is GatewayCaller {
    function onDecryptionResult(uint256, uint32) public onlyGateway { /* ... */ }
}
```

**Why the agent will generate this:** Same root cause as 1.1. The gateway model had its own inheritance hierarchy (`GatewayCaller`) and oracle contract (`DecryptionOracle`) that contracts inherited from or imported. Training-data examples using the pre-v0.9 flow almost always include one of these three symbols.

**Correct replacement:** No inheritance is needed for decryption in v0.10+. Use `FHE.makePubliclyDecryptable(handle)` for public decryption (plaintexts emerge off-chain via the relayer) or EIP-712-signed user decryption via `@zama-fhe/relayer-sdk` in the frontend. See `references/decryption.md`.

**Caught by:** `lint-antipatterns.js` substring scan for `DecryptionOracle`, `GatewayCaller`, `onDecryptionResult`. `verify-env.sh` does not check for these directly (FHE.sol doesn't re-export them) but their use will fail at Solidity compile time.

---

### 1.3 `import {SepoliaConfig}`  [mock-verified 2026-04-17]

**Pattern to refuse:**
```solidity
// BROKEN — per-network config consolidated in v0.10
import {SepoliaConfig} from "@fhevm/solidity/config/ZamaConfig.sol";

contract MyContract is SepoliaConfig { /* ... */ }
```

**Why the agent will generate this:** Pre-v0.10, each supported network had its own config contract (`SepoliaConfig`, `MainnetConfig`, etc.) that contracts inherited from. This was the canonical pattern in examples dated through late 2025. An agent scaffolding a new FHEVM contract will reach for `SepoliaConfig` specifically when the user mentions Sepolia, which is the default testnet.

**Correct replacement:**
```solidity
import {ZamaEthereumConfig} from "@fhevm/solidity/config/ZamaConfig.sol";

contract MyContract is ZamaEthereumConfig { /* ... */ }
```

`ZamaEthereumConfig` resolves the correct coprocessor addresses at runtime based on `block.chainid` — one config contract covers Sepolia, mainnet, and any future Ethereum-side deployments.

**Caught by:** `verify-env.sh` Check 4 greps `ZamaConfig.sol` for `SepoliaConfig` absence; `lint-antipatterns.js` substring scan for `import {SepoliaConfig`.

---

*Entries 1.4–1.6 below are earlier (v0.7-era) renames and removals. Less common in current training data than 1.1–1.3 above, but still generated by models trained on the oldest FHEVM corpus. Included for defense-in-depth. Entry 1.4 carries an additional hazard — Hardhat actively suggests the wrong fix — that is called out inline.*

---

### 1.4 `TFHE` library name  [mock-verified 2026-04-17]

**Pattern to refuse:**
```solidity
// BROKEN — library renamed in v0.7, old import path no longer resolves
import {TFHE, euint32} from "fhevm/lib/TFHE.sol";

contract StaleTFHE {
    euint32 private _count;
    constructor() {
        _count = TFHE.asEuint32(0);
    }
}
```

**Why the agent will generate this:** The library was named `TFHE` (short for "Torus FHE," the underlying cryptographic scheme) through v0.6, imported from `fhevm/lib/TFHE.sol`. Many tutorials and the original Zama documentation used `TFHE.add`, `TFHE.allow`, etc. The rename to `FHE` and move to `@fhevm/solidity` happened in v0.7, but training data still contains both names and the older form is more prevalent by volume.

**Compile error observed:**
```
Error HH411: The library fhevm, imported from contracts/_stale_tfhe.sol,
is not installed. Try installing it using npm.
```

**Hardhat's suggested fix is wrong and dangerous.** Do not run `npm install fhevm`. The `fhevm` npm package is the unmaintained pre-v0.7 package; installing it will resolve the HH411 error and let `TFHE`-era code compile, producing a *contaminated codebase where ancient cryptography appears to work*. The TFHE-era contracts will use old protocol semantics that the current v0.10+ coprocessor does not speak correctly. This failure mode is silent: contracts compile, tests may pass against the old library's mock, and the system is broken in ways that only surface against a live coprocessor.

**Correct fix:** Rewrite the import as:
```solidity
import {FHE, euint32} from "@fhevm/solidity/lib/FHE.sol";
```
and rename every `TFHE.X` call to `FHE.X`. Do not alter package installation.

This is a CR-2 extension worth internalizing: **trust the grep, not the tool's suggestion.** When a compiler or package manager suggests a fix that would install a package, verify against `node_modules/@fhevm/solidity/` that the suggested package is actually the canonical source, not a deprecated predecessor.

**Caught by:** Fails at Hardhat resolution stage with `HH411` — clear signal, but the suggested remediation is a trap. `lint-antipatterns.js` does not currently scan for the `fhevm/` import prefix; adding it is a candidate for the lint script if the trap proves common in practice.

---

### 1.5 `einput` type  [mock-verified 2026-04-17]

**Pattern to refuse:**
```solidity
// BROKEN — type renamed in v0.7
function increment(einput encAmount, bytes calldata inputProof) external {
    euint32 amount = FHE.asEuint32(encAmount, inputProof);
}
```

**Why the agent will generate this:** Pre-v0.7, all encrypted inputs arrived as the single `einput` type regardless of their eventual decoded type; the receiving function used `TFHE.asEuintXX` to parse the input. This pattern is heavily represented in pre-2025 FHEVM examples and often appears in code snippets that otherwise look current.

**Compile error observed:**
```
DeclarationError: Identifier not found or not unique.
 --> contracts/_stale_einput.sol:9:24:
  |
9 |     function increment(einput encAmount, bytes calldata inputProof) external {
  |                        ^^^^^^
```

**Correct replacement:** Use the typed external variants — `externalEuint32`, `externalEbool`, `externalEaddress`, etc. Convert with `FHE.fromExternal(encInput, inputProof)`:

```solidity
function increment(externalEuint32 encAmount, bytes calldata inputProof) external {
    euint32 amount = FHE.fromExternal(encAmount, inputProof);
}
```

The typed external variants are declared in `encrypted-types/EncryptedTypes.sol`; see `references/input-proofs.md` for the full pattern.

**Caught by:** Fails at Solidity compile time with a clear `DeclarationError`. Unlike entry 1.4, the compiler's error points at the exact problem — no tooling trap. Agent should refuse to generate `einput` in any new code regardless.

---

### 1.6 Pre-v0.7 implicit `ebytesXX` declarations  [mock-verified 2026-04-17 — partial; see scope note]

**Pattern to refuse:**
```solidity
// BROKEN — pre-v0.7 contracts used ebytesXX types implicitly via the TFHE import
contract StaleEbytes {
    ebytes32 private _data;  // no explicit import; relied on TFHE's import model
}
```

**Why the agent will generate this:** In pre-v0.7 FHEVM, `ebytesXX` types were transitively available when a contract imported from `TFHE.sol`, with no separate import needed for the types themselves. Training-data examples use `ebytes32` (and siblings) as if they are built-in Solidity types. An agent scaffolding a contract that stores an encrypted hash or byte-array will reach for `ebytes32` directly, without importing it.

**Compile error observed:**
```
DeclarationError: Identifier not found or not unique.
 --> contracts/_stale_ebytes.sol:7:5:
  |
7 |     ebytes32 private _data;
  |     ^^^^^^^^
```

**Scope of what this test proves.** The compile error confirms only that the pre-v0.7 pattern — declaring `ebytes32` without importing it — fails in the current toolchain. It does **not** prove `ebytes32` is removed from the library.

The current `encrypted-types` package (v0.0.4, verified by grep against `EncryptedTypes.sol`) includes `ebytes1` through `ebytes32` as declarations. An agent who explicitly imports them — `import {ebytes32} from "encrypted-types/EncryptedTypes.sol";` — will pass the `DeclarationError` and compile. Whether the resulting semantics match the pre-v0.7 types of the same name is not documented in this skill; if encountered in user code, grep `EncryptedTypes.sol` and the Zama docs before use.

**Correct replacement for the refused pattern.** Two possibilities depending on intent:

- If the agent wants encrypted byte storage and the modern `ebytes*` types are appropriate: import them explicitly and proceed with caution (semantics unverified here).
- If the agent is translating pre-v0.7 code that used `ebytes32` for a hash or small blob: consider whether the current design can use multiple `euint*` fields instead (composed arithmetic is well-understood), or treat the blob as plaintext `bytes` and handle encryption at the frontend boundary.

**Caught by:** Fails at Solidity compile time with `DeclarationError` for the implicit-usage pattern. Does not catch the explicit-import case, which compiles and then succeeds or fails based on runtime semantics this skill has not verified.

---

## Section 2 — Stale layout assumptions

### 2.1 Assuming encrypted types live in `@fhevm/solidity`  [mock-verified 2026-04-17]

**Pattern to refuse:** Greping `node_modules/@fhevm/solidity/lib/FHE.sol` for `type euint32 is bytes32;` (or similar type declarations), concluding the types don't exist, and generating workaround code.

**Why the agent will generate this:** The natural assumption is that a type used throughout `@fhevm/solidity` is *declared* in `@fhevm/solidity`. FHE.sol uses `euint32` on every other line but declares none of them. The types are declared in a transitive dependency: `encrypted-types` (authored by the Confidential Token Association, not Zama directly), imported at the top of FHE.sol via `import "encrypted-types/EncryptedTypes.sol";`.

An agent greping FHE.sol for type declarations will wrongly conclude the types don't exist. This was caught by the skill's own author during `verify-env.sh` review — the script's first draft greped FHE.sol for type declarations, all ten type checks failed, and the root cause was this layout assumption.

**Correct replacement:** Grep `node_modules/encrypted-types/EncryptedTypes.sol` for type declarations. Grep `node_modules/@fhevm/solidity/lib/FHE.sol` for function declarations. Two different files, two different concerns.

**Caught by:** `verify-env.sh` Check 3a (types) separately from Check 3b (functions). If the script is modified to route type checks back through FHE.sol, it will fail the same way the first draft did — and that failure will surface this layout gotcha immediately.

---

### 2.2 Assuming `@fhevm/hardhat-plugin` built output lives at `dist/`  [mock-verified 2026-04-17]

**Pattern to refuse:** Greping `node_modules/@fhevm/hardhat-plugin/dist/` for plugin symbols and assuming their absence means the plugin is broken.

**Why the agent will generate this:** `dist/` is the conventional output directory for most npm TypeScript packages. The `@fhevm/hardhat-plugin` uses `_types/` (type declarations) and `_cjs/` (built CommonJS) instead. An agent running a grep against the expected `dist/` path will find nothing, conclude the plugin is not properly installed, and waste time on environment debugging.

**Correct replacement:** Grep all three common paths when looking for plugin symbols: `_types/`, `_cjs/`, and `dist/`. The `verify-env.sh` script's Check 5 does this by building a search-path list from whichever directories exist.

**Caught by:** `verify-env.sh` Check 5 handles this transparently for the skill's standard symbol checks. Manual greps during debugging should search all three paths.

---

## Section 3 — Stale testing patterns

### 3.1 `Promise.all` around `fhevm.publicDecryptEuint` / `userDecryptEuint`  [mock-verified 2026-04-17]

**Pattern to refuse:**
```typescript
// BROKEN — races the mock coprocessor's event cursor
const [a, b, c] = await Promise.all([
    fhevm.publicDecryptEuint(FhevmType.euint32, handleA),
    fhevm.publicDecryptEuint(FhevmType.euint32, handleB),
    fhevm.publicDecryptEuint(FhevmType.euint32, handleC),
]);
```

**Why the agent will generate this:** `Promise.all` is the idiomatic JavaScript pattern for running independent async operations concurrently. The agent has no reason from reading the type signature of `publicDecryptEuint` alone to suspect it has concurrency constraints — the signature looks like any other `Promise<bigint>`-returning function. The failure mode is subtle: small inputs race benignly and the test passes; larger inputs fail with an error inside `@fhevm/hardhat-plugin/.../BlockLogCursor` that points nowhere useful.

**Correct replacement:**
```typescript
const a = await fhevm.publicDecryptEuint(FhevmType.euint32, handleA);
const b = await fhevm.publicDecryptEuint(FhevmType.euint32, handleB);
const c = await fhevm.publicDecryptEuint(FhevmType.euint32, handleC);
```

Sequential `await`s. Three extra lines per multi-decrypt test, no runtime penalty. See CR-3 in `references/core-rules.md` for the full treatment.

**Caught by:** `lint-antipatterns.js` scans test files for `Promise.all(` within a block that also contains `publicDecryptEuint` or `userDecryptEuint`.

---

## Section 4 — Stale Solidity-intuition patterns

### 4.1 `if` or `require` on an encrypted boolean  [docs-sourced]

**Pattern to refuse:**
```solidity
// IMPOSSIBLE — cannot branch Solidity control flow on encrypted values
ebool isEligible = FHE.gt(amount, threshold);
if (isEligible) {                           // does not compile / does not work
    _approved = true;
}
require(FHE.eq(input, secret), "no match"); // same problem
```

**Why the agent will generate this:** Every Solidity developer's first instinct for conditional logic is `if` or `require`. When a predicate returns a boolean-shaped value (`ebool`), the natural next line is to branch on it. But `ebool` is a handle to an encrypted value living in the coprocessor — it has no plaintext representation the EVM can test. The EVM cannot branch on what it cannot see.

**Correct replacement:** Use `FHE.select(cond, ifTrue, ifFalse)` — a branchless conditional that returns an encrypted value chosen by the encrypted condition:

```solidity
ebool isEligible = FHE.gt(amount, threshold);
euint32 result = FHE.select(isEligible, yesValue, noValue);
FHE.allowThis(result);
FHE.allow(result, reader);
```

If the branch condition must gate a *plaintext* state change (e.g., setting a public bool), the check must be performed off-chain after decryption, or the contract must be restructured so the gated state is itself encrypted. Plaintext branches on encrypted conditions are impossible by design; this is a cryptographic property, not a library limitation.

See `references/operations.md` for the full `FHE.select` pattern and common compositions.

**Caught by:** Fails at Solidity compile time with a type-mismatch error (`ebool` cannot be converted to `bool`). `lint-antipatterns.js` does not currently check for this because the compile error is immediate and informative. Flagged here so the agent refuses to generate it.

---

### 4.2 Granting caller ACL on aggregate state to "let users verify their input"  [mock-verified 2026-04-17]

**Pattern to refuse:**
```solidity
// LEAKS AGGREGATE STATE — msg.sender can now decrypt the full tally
function vote(externalEuint32 encWeight, bytes calldata proof) external {
    euint32 weight = FHE.fromExternal(encWeight, proof);
    _tally = FHE.add(_tally, weight);
    FHE.allowThis(_tally);
    FHE.allow(_tally, msg.sender);  // WRONG — voter can now read everyone's cumulative total
}
```

**Why the agent will generate this:** Standard access-control intuition says "if I contributed to this value, I should be able to read it." In a plaintext voting contract, a voter verifying their vote means reading back the state their vote affected. The agent reaches for `FHE.allow(_tally, msg.sender)` because that's the straightforward translation of "let the caller see the result."

The translation is wrong. In FHEVM, ACL is per-handle, not per-logical-value. Granting the caller access to the aggregate tally handle gives them decryption rights on the running total of *everyone's* votes, not just their own contribution. This is a confidentiality failure — the contract compiles, the tests pass (if they only test the happy path), and the aggregate leaks to every voter.

**Correct replacement:** Per-voter storage with per-voter ACL:

```solidity
mapping(address => euint32) voterContribution;

function vote(externalEuint32 encWeight, bytes calldata proof) external {
    euint32 weight = FHE.fromExternal(encWeight, proof);

    voterContribution[msg.sender] = weight;
    FHE.allowThis(voterContribution[msg.sender]);
    FHE.allow(voterContribution[msg.sender], msg.sender);  // voter reads own contribution only

    _tally = FHE.add(_tally, weight);
    FHE.allowThis(_tally);
    FHE.allow(_tally, admin);  // only admin reads the aggregate
}
```

Two separate ACL grants, on two separate handles, to two separate addresses.

**Caught by:** No automated check — this requires semantic understanding of which handle should be readable by whom. The defense is agent discipline: every `FHE.allow(handle, addr)` line in a generated contract must map to a specific, articulable use case. An allow line granted "because the caller contributed" is presumed wrong.

This is the only silent-confidentiality-failure pattern in this file. Every other refused pattern in 1.x, 2.x, 3.x, and elsewhere in 4.x fails at compile time, fails at test time, or produces an obvious runtime error. Entry 4.2 is categorically different: the contract compiles clean, the happy-path tests pass, and production leaks. The pattern is subtle, the failure is silent, and every voting / auction / polling / collaborative-computation contract is susceptible. See CR-1's conceptual sharpening in `references/core-rules.md` for the mental model.

---

### 4.3 Single `allowThis` in constructor with no re-grants after operations  [mock-verified 2026-04-17]

**Pattern to refuse:**
```solidity
constructor() {
    _count = FHE.asEuint32(0);
    FHE.allowThis(_count);   // only grant, never renewed
}

function increment(externalEuint32 encAmount, bytes calldata proof) external {
    euint32 amount = FHE.fromExternal(encAmount, proof);
    _count = FHE.add(_count, amount);
    // MISSING: FHE.allowThis(_count) after the op
}
```

**Why the agent will generate this:** Constructor-only ACL grants are the Solidity pattern for "set up permissions once, reuse them forever." Standard access-control models work this way — an `onlyOwner` modifier checks a single stored address regardless of how many times the state mutates.

FHEVM breaks the assumption. Every FHE operation produces a new handle. ACL is attached to handles, not slots. The `_count` after `FHE.add` is a different handle than the `_count` set in the constructor, and it has zero ACL.

**Correct replacement:** Re-grant ACL on every new handle, in every function that mutates encrypted state. See CR-1 for the full rule and `references/access-control.md` for the patterns.

**Caught by:** No lint check — detecting missing re-grants requires dataflow analysis of handle assignments, which is too fragile for regex. The defense is agent discipline (CR-1 internalized) and tests that exercise every state-mutation path with a subsequent read to verify the ACL is in place.

---

## What this file does not cover

- **New encrypted types added in post-v0.10 releases** (signed `eint*`, byte-array `ebytes1`–`ebytes32`). The author has no lived experience with these and no log backing. When an agent needs them, grep `EncryptedTypes.sol` and the Zama docs for current guidance.

- **HCU (homomorphic compute unit) exhaustion.** See `references/operations.md` for the concept and limits pointer. Not an anti-pattern per se but a category of runtime failure with similar "stale assumption" character (agents assume FHE ops are free the way EVM ops are cheap; they aren't).

- **Relayer SDK staleness.** Parallel structure exists on the frontend side: `@zama-fhe/relayer-sdk` has its own version history with removed/renamed APIs. `references/frontend-integration.md` covers the frontend-specific cases when drafted.

- **Future anti-patterns.** Per CR-2, this file is not exhaustive. When an agent encounters a symbol or pattern not covered here, the grep-before-trust workflow is the durable defense.
