# FHEVM Footgun Log

Every time I hit a wall, error, or "wait that shouldn't happen" moment, it goes here.
Raw notes — no polish. This becomes the anti-patterns section of the skill.

## Format
- **What I was trying to do:** 
- **What happened:**
- **Error message (if any):**
- **Time wasted:** (rough, in minutes)
- **Fix:**
- **Why I didn't see it coming:** ← this line is the gold

---

## Entries

### 2026-04-17 — `SepoliaConfig` import does not exist
- **What I was trying to do:** Compile `ConfidentialCounter.sol` using the scaffold's `import {SepoliaConfig} from "@fhevm/solidity/config/ZamaConfig.sol";`
- **What happened:** Hardhat refused to compile on the import line.
- **Error message:** `DeclarationError: Declaration "SepoliaConfig" not found in "@fhevm/solidity/config/ZamaConfig.sol"`
- **Time wasted:** ~2 min
- **Fix:** The current `@fhevm/solidity` package only exports one config: `ZamaEthereumConfig`. Swapped the import and the `is SepoliaConfig` base to `ZamaEthereumConfig`. Also confirmed `contracts/FHECounter.sol` (reference) uses the same name.
- **Why I didn't see it coming:** I assumed per-network config contracts (`SepoliaConfig`, `MainnetConfig`, etc.) still existed because older Zama docs and blog posts use that name. The library has consolidated — there's now a single `ZamaEthereumConfig` regardless of target network. Lesson: **when in doubt, grep `node_modules/@fhevm/solidity/` before trusting a name from a doc page.** The docs may be versioned behind the installed package.

### 2026-04-17 — ACL follows handle production, not data contribution (CONCEPTUAL)
- **What I was trying to do:** Reason about who should be able to read `_count` after Alice (a non-owner) increments it.
- **What happened:** My first instinct was "Alice contributed the encrypted 3, so Alice should be able to decrypt the resulting count." That instinct is wrong — and dangerously intuitive.
- **Error message:** None. Test 6 passed on the first run *because* the ACL works this way; the bug is in the mental model, not the code.
- **Time wasted:** 0 minutes solving it, but this is the single most load-bearing FHEVM concept for an AI agent writing contracts. Getting it wrong silently produces "leaky" contracts where state is readable by parties the author didn't intend.
- **Fix:** Internalize this rule and never forget it:
  > **The ACL on a handle is set by whoever produces the handle, and the producer is always the contract currently executing `FHE.add` / `FHE.sub` / `FHE.select` / etc. Inputs coming in via `FHE.fromExternal` get transient access for the contract only; they do *not* persist access for the submitter.**
  So when Alice submits encrypted 3 and the contract does `_count = FHE.add(_count, amount)`, the new `_count` is a fresh handle, and its ACL is whatever the contract explicitly grants via `FHE.allowThis` / `FHE.allow`. In my contract: `allowThis(_count); allow(_count, owner);` — no grant to `msg.sender`, so Alice can't read the state she helped shape.
- **Why I didn't see it coming:** Every non-FHE database/blockchain system I've worked with grants some form of read-visibility to contributors by default (event logs, return values, state that anyone can read). FHEVM inverts this: contribution is a write-only act by default, and read access is an *explicit*, per-handle grant. If you're porting a mental model from Solidity where `msg.sender` of a setter function typically has implicit read rights, you will write ACL bugs. **Treat every `FHE.add`/`FHE.sub`/etc. as producing a NEW handle that has ZERO ACL unless you explicitly grant.**

### 2026-04-17 — When a test's semantics change, delete-and-replace (don't flip the assertion) (TESTING HYGIENE)
- **What I was trying to do:** Update the "owner calling getCount() immediately after deploy reverts" test after fixing the constructor to grant owner ACL.
- **What happened:** Naive instinct: flip the assertion from `revertedWith("not allowed")` to `expect(clear).to.eq(0)` and leave the test name alone. The test would pass, but anyone reading the describe-block later would see a test named "owner read reverts" that actually asserts success. A liar.
- **Error message:** None — this is a hygiene issue, not a compile/runtime one.
- **Time wasted:** ~0 min (the guidance was given), but worth logging because it generalizes.
- **Fix:** Delete the test entirely, write a new one with a name that matches the new semantics. Mutating a test's body while keeping its name is a small-but-corrosive form of lying to future readers. Trust the diff tool to preserve history if you want to see what the old assertion was.
- **Why I didn't see it coming:** This isn't FHEVM-specific at all, but matters *extra* in FHEVM because test names frequently encode ACL expectations (`"owner can read X"`, `"non-owner cannot read Y"`), and those expectations are the spec. A test whose name lies about its ACL assertion is a time bomb for anyone — human or agent — trying to reason about what the contract guarantees.

### 2026-04-17 — Verified negative: trivially-encrypted constants decrypt identically to operation results (in mock)
- **What I was trying to do:** Check whether `fhevm.userDecryptEuint` behaves the same on a handle produced by `FHE.asEuint32(0)` (constructor) versus a handle produced by `FHE.add` (increment result).
- **What happened:** Both decrypt cleanly to their plaintext value in mock mode. No difference observed.
- **Error message:** None.
- **Time wasted:** ~0 min.
- **Fix:** N/A — but worth recording as a negative result so I don't re-investigate it. **Caveat:** this was verified only in `fhevm.isMock` mode. Not yet verified against a real Sepolia relayer; behavior there could in principle differ (e.g., trivial encryptions may route through a different KMS path). If we deploy to Sepolia in a later phase, re-check this and log if it diverges.
- **Why I flagged it in advance:** It is theoretically possible for a mock plugin to short-circuit trivial-encryption paths and hide bugs that would surface on a live network. Being explicit about "I verified X, but only in mock" prevents future-me from treating a mock-only verification as a universal truth.

### 2026-04-17 — Meta-note: the right test for a conceptual footgun (METHOD)
- **The mistake I was about to make:** Treat "did this confuse me personally?" as the criterion for whether a conceptual FHEVM rule is skill-worthy. That's the wrong criterion.
- **The right criterion:** "Would standard Solidity / EVM intuition lead an agent to the wrong answer here?" Agents are trained on the entire Solidity corpus; their priors are *inherited from that corpus*. The ACL-follows-production rule is footgun-worthy not because any particular human was confused, but because the standard Solidity prior — "if I contributed data to a function, I can probably read related data back" — is the prior the model will reach for by default. The rule's job in the skill is to name that prior explicitly and override it.
- **How to apply:** When deciding whether a concept earns a log entry:
  1. State the rule in one sentence.
  2. State the Solidity/EVM default intuition in one sentence.
  3. If #1 contradicts #2, it's skill-worthy regardless of whether I personally had a gut-check moment about it.
  4. First-time-me's confusion is a useful signal but not a necessary one. An agent is not me; an agent has never seen FHEVM before but has seen thousands of Solidity contracts where input-contribution implied read-back.
- **Why this matters for the skill:** If I only document what confused me, I will systematically under-document the things I happened to read about in advance. The skill's job is to counter-train the model's strongest wrong priors, not to mirror my personal learning path.

### 2026-04-17 — **HEADLINE ANTI-PATTERN: Trusting pre-v0.9 decryption API patterns**

> The `FHE.requestDecryption(handles, callbackSelector)` → gateway callback → `checkSignatures` flow was the idiomatic public-decryption pattern in FHEVM v0.7–v0.8. It was removed during the v0.9 consolidation and does not exist in `@fhevm/solidity` v0.10+. Most tutorials, blog posts, and LLM training data still reference it. Before writing any decryption code, grep the installed library:
> ```bash
> grep -r "requestDecryption" node_modules/@fhevm/solidity/lib/FHE.sol
> ```
> If it returns nothing, use the v0.11 pattern instead: `FHE.makePubliclyDecryptable(handle)` for public reveal (plaintext lives off-chain, accessed via relayer), or user-decryption via `fhevm.userDecryptEuint` in tests and `relayer-sdk` in frontends. **Treat any generated code containing `requestDecryption`, `DecryptionOracle`, `Gateway.sol`, or `onDecryptionResult` callbacks as stale.**

- **Concrete evidence I gathered:**
  - Installed versions: `@fhevm/solidity@0.11.1`, `@fhevm/hardhat-plugin@0.4.2`, `@fhevm/host-contracts@0.10.0`.
  - `grep -rn "requestDecryption" node_modules/@fhevm/solidity/` → **zero matches**.
  - `grep -rn "DecryptionOracle\|Gateway\.sol" node_modules/@fhevm/` → **zero matches**.
  - What *does* exist in this version:
    - `FHE.makePubliclyDecryptable(value)` per type (`ebool`, `euint8/16/32/64/128/256`, etc.)
    - `FHE.isPubliclyDecryptable(value)` — view check
    - `FHE.checkSignatures(bytes32[] handlesList, bytes abiEncodedCleartexts, bytes decryptionProof)` — for dApps that DO receive plaintext on-chain via a caller-submitted signed result, but the library no longer ships the oracle/gateway that produces the callback. You build the entry point yourself.
  - Plugin helper for tests: `fhevm.publicDecryptEuint(FhevmType.euint32, handle, options?)` — off-chain public decryption via the mock relayer. No on-chain callback involved.

- **Why this will catch agents:** the pre-v0.9 pattern was the only documented public-decryption approach for ~18 months of Zama development. Every tutorial, example, and GitHub repo from that era uses it. Training data for current LLMs is saturated with it. An agent asked to write "a vote contract where tallies are revealed after a deadline" will, by default, produce code that:
  1. Calls `FHE.requestDecryption(...)` — doesn't compile, symbol is gone.
  2. Defines a `callbackReveal(uint256 requestId, uint32[] plaintexts, bytes[] signatures)` — wrong shape for v0.11 anyway.
  3. Inherits from `GatewayCaller` or similar — no such contract ships.
  4. References `Gateway.sol` — removed.
  The skill must name all four patterns explicitly and redirect to `makePubliclyDecryptable` + off-chain decryption.

- **Why I didn't see it coming (even with my own priors):** I spent a good chunk of my own "instinct" on this wall — I expected `FHE.requestDecryption` to exist in some form because the coach's spec called for it. I only found out it was gone by exhausting the grep and then reading the actual ACL/public-decryption functions in `FHE.sol`. The coach had the same stale prior and wrote the spec based on it. **The system worked only because I greped before implementing; had I tried to "make it compile" by guessing, I would have wasted an hour generating plausible-looking-but-wrong code.**

- **The process rule this entry establishes (applies to all of Phase 1 and Phase 2):**
  Before implementing a spec that uses any FHEVM symbol I haven't personally used in *this* repo yet, run:
  ```bash
  grep -n "<SymbolName>" node_modules/@fhevm/solidity/lib/FHE.sol
  ```
  and for plugin helpers:
  ```bash
  grep -rn "<HelperName>" node_modules/@fhevm/hardhat-plugin/_types/
  ```
  (Note: the plugin's built output lives in `_cjs/` and `_types/`, **not** `dist/` — a common copy-paste footgun in grep instructions written for older plugin versions.) If the grep returns nothing, stop and flag to the coach before writing any code. Stale-API hallucinations are the highest-cost, lowest-visibility failure mode in FHEVM work, and they're prevented by one grep.

### 2026-04-17 — `publicDecryptEuint` (and siblings) returns `bigint`, not `number`

> The hardhat-plugin's decryption helpers return JavaScript `bigint` (the native arbitrary-precision type, literal suffix `n`), **not** `number`. Chai's `.to.eq(5)` will silently fail against `5n` because `bigint` and `number` are never equal under strict equality. Use `.to.eq(5n)` with the `n` suffix, or explicitly coerce with `Number(clear)` if the value is guaranteed to fit in a safe integer range. An agent generating tests from Solidity-side intuition will almost always write `.to.eq(5)` and get a confusing failure message.
>
> Applies to `publicDecryptEuint`, `userDecryptEuint`, and any decrypt helper returning `uint64` or larger — `euint8`/`euint16`/`euint32` technically fit in `number` but the plugin returns `bigint` uniformly for consistency.

- **Source of truth:** signature in `node_modules/@fhevm/hardhat-plugin/_types/types.d.ts:77`:
  ```ts
  publicDecryptEuint(fhevmType: FhevmTypeEuint, handleBytes32: string, options?: FhevmPublicDecryptOptions): Promise<bigint>
  ```
- **How the confusing failure actually manifests in chai (worth knowing by sight):**
  ```
  AssertionError: expected 5n to equal 5
   +5
   -5n
  ```
  The `+` and `-` are identical-looking in a terminal scan; the `n` suffix is the only signal. Agents (and humans) skim past it and waste minutes re-checking the contract instead of the test.
- **Related gotcha:** `await contract.someUint256Getter()` in ethers v6 also returns `bigint` for all Solidity `uint*` types. So `expect(await contract.deadline()).to.eq(3600)` will *also* fail if the contract stored `deadline` as a `uint256` — because the ABI decoder returns `bigint` uniformly. Fix: wrap the expected value in `BigInt(...)` or use the `n` suffix.
- **Why I didn't see it coming (even after flagging it):** my first instinct was to think this only bit on very large numbers. It doesn't. The plugin / ethers returns `bigint` *regardless of the source type's range*, for consistency. Treat every Solidity-to-JS numeric crossing as `bigint` by default.
- **Process note:** the cost of getting this wrong is a confusing test failure, not a silent bug — chai will complain. But agents burn time on the wrong hypothesis ("is my contract broken?") before checking the assertion types. Skill should name it explicitly so the first debugging step is "is this a bigint/number mismatch?".

### 2026-04-17 — PROSPECTIVE: Anticipated footguns for ConfidentialVote (before writing code)

Predictions — not claims. Two things I expect to trip me, based on what I already know about ACL, handle mutation, and the v0.11 API:

1. **Per-branch `FHE.allowThis` re-grants.** The `vote` function has three branches (candidate 0/1/2), each of which mutates a tally's handle via `FHE.add`. Every branch needs its own `FHE.allowThis` on the *new* handle. I expect to either forget one of them or typo the tally variable, and the first failing vote will show up as an ACL error. Rule being tested: handle mutates per op, ACL must be re-granted per handle.
2. **`makePubliclyDecryptable` behavior on un-voted-for tallies.** In test 6, candidates B and C never receive a vote — their `_tally` is still the constructor-time `FHE.asEuint32(0)` handle. My model says `makePubliclyDecryptable` should work on those handles since the contract has `allowThis` from the constructor, and `publicDecryptEuint` should return 0n. But this is the first test where I'm combining *trivial encryption* (`asEuint32(0)`) with *public decryption* — the counter only exercised user-decryption on trivial encryptions. If mock's public-decryption path short-circuits, hangs, or errors on a never-operated-on handle, I'll find out here.

Will compare these predictions to what actually hits after the test run.

### 2026-04-17 — `Promise.all` of parallel `publicDecryptEuint` calls races the mock coprocessor's event cursor

> **Calling `fhevm.publicDecryptEuint` in parallel via `Promise.all([...])` crashes the mock coprocessor with a cursor race** when the test has produced enough events. The mock's `BlockLogCursor` is not concurrency-safe — multiple decrypt calls try to advance through the same event log cursor simultaneously and one of them throws `Parse event at blockNumber=N, logIndex=M in backward order. Current blockNumber=N, logIndex=M`. **Always `await` decryption calls sequentially in tests**, even when the handles are independent and you'd intuitively expect the calls to be parallelizable.

- **Exact error surface:**
  ```
  Error: Parse event at blockNumber=21, logIndex=1 in backward order. Current blockNumber=21, logIndex=1
    at BlockLogCursor.updateForward (node_modules/@fhevm/mock-utils/ethers/event.ts:154:13)
    at CoprocessorEventsIterator.next (.../CoprocessorEventsIterator.ts:44:20)
    at MockCoprocessor.awaitCoprocessor (.../MockCoprocessor.ts:62:40)
    ...
    at async Promise.all (index 0)
  ```
  The `Promise.all (index 0)` line in the stack is the smoking gun.
- **When it bites vs. when it doesn't:** test 6 in my suite (1 vote, 3 decrypts via `Promise.all`) **passed** — because fewer coprocessor events means the cursor race doesn't manifest. Test 5 (3 votes, 3 decrypts via `Promise.all`) **failed** — enough events to expose the race. **This is the worst kind of flake**: a test that passes on small inputs and fails on larger ones, with a mock-internal error message that doesn't obviously point to concurrency.
- **Fix:** replace
  ```ts
  const [a, b, c] = await Promise.all([
    fhevm.publicDecryptEuint(FhevmType.euint32, hA),
    fhevm.publicDecryptEuint(FhevmType.euint32, hB),
    fhevm.publicDecryptEuint(FhevmType.euint32, hC),
  ]);
  ```
  with sequential awaits:
  ```ts
  const a = await fhevm.publicDecryptEuint(FhevmType.euint32, hA);
  const b = await fhevm.publicDecryptEuint(FhevmType.euint32, hB);
  const c = await fhevm.publicDecryptEuint(FhevmType.euint32, hC);
  ```
- **Why this is a tier-one agent footgun:** `Promise.all` is the idiomatic JS pattern for "I have N independent async operations, I want them all done." An agent writing tests from TypeScript intuition will reach for it by default. The mock's cursor race is an *implementation detail* of `@fhevm/mock-utils`, not a semantic property of FHEVM — but the test will fail and the error message points inside node_modules, not at the test. Without this entry, an agent (or human) will spend 30+ minutes hypothesizing "is the contract wrong? is the reveal logic wrong? is `publicDecryptEuint` broken on one of my handles?" before suspecting the `Promise.all` itself.
- **Does it also bite `userDecryptEuint`?** I haven't tested in the same way — my counter tests only did one user-decryption per test. **Safe default: serialize all fhevm decrypt helpers in tests until proven otherwise.** If someone proves parallel works for user-decryption, update this entry; until then, the "sequential only" rule is the safe generalization.
- **Why I didn't see it coming (despite flagging bigint and predicting other things):** I had no mental model of the mock coprocessor's internals. `Promise.all` felt like free optimization for independent decrypts. I was reasoning at the level of the public plugin API, not at the level of the mock's event-cursor implementation. Lesson: **the mock is not an identity transform of the real chain — it has its own constraints that don't show up in the plugin's type signatures.** Plugin helpers that look parallelizable may not be.

### 2026-04-17 — RETROSPECTIVE: ConfidentialVote predictions vs. reality

Comparing the prospective entry above against what actually happened:

- **Prediction 1 (per-branch `allowThis` re-grants) — DID NOT FIRE.** The contract compiled first try and all 6 tests passed after one fix. I remembered all three `FHE.allowThis` calls in the `vote` branches. Possible reason it felt like a strong prediction: I'd just hit the same rule in the counter's `increment`, so it was salient and I wrote the contract with it front-of-mind. *Lesson: the rule becomes "free" once you've personally paid for it in a prior contract. Agents who've only read about it in a skill entry haven't "paid" — the prediction is still valid for them.*

- **Prediction 2 (`makePubliclyDecryptable` on never-operated handles) — DID NOT FIRE.** Test 6 revealed tallies B and C (constructor-time `FHE.asEuint32(0)`, never touched by `FHE.add`) and they decrypted cleanly to `0n` via `publicDecryptEuint`. Same conclusion as the earlier "trivially-encrypted constants decrypt identically to operation results" negative-result entry — now reconfirmed for the public-decryption path too, not just user-decryption. Still mock-only; still worth re-verifying on real Sepolia before trusting this broadly.

- **WHAT I DID NOT PREDICT AND GOT BURNED BY — the `Promise.all` cursor race on `publicDecryptEuint` (logged above).** This was the actual footgun of the round. It's a concurrency bug in the mock coprocessor's event cursor, completely outside my mental model before writing the test. It manifests as a flake (passes on small inputs, fails on large) with an internal mock error message. **This is a stronger anti-pattern than either of my predictions, and I would not have written it in the log had the test not actually failed.**

- **What the prediction exercise got me anyway, even though both were wrong:** writing them down made me attentive to the `allowThis` pattern while coding (I wrote all three re-grants deliberately rather than autopilot), and made me check `publicDecryptEuint` on trivial encryptions specifically in test 6 rather than skipping to "obviously it works." Both of those vigilances were useful even though neither turned into an entry. Prospective entries are not "cheap retrospective entries" — they're cognitive scaffolding that shapes the coding, whether or not they end up validated.

- **Meta-lesson for the skill:** the highest-value entries are *not* predictable by someone who's internalized the rules. The Promise.all/cursor-race entry is valuable precisely because it lives outside the usual FHEVM mental model (ACL, handles, encrypted types) — it's a property of the *testing tooling*, not the protocol. An agent reading the skill needs both kinds of entries: the predictable ones (ACL rules, handle mutation) that prevent obvious mistakes, and the tooling-surface entries (bigint returns, cursor races, missing symbols) that prevent non-obvious failures from research-time tools.

### 2026-04-17 — Encrypted types live in the `encrypted-types` package, not `@fhevm/solidity`

> FHEVM's `euint*`, `ebool`, `eaddress`, and `externalEuint*` types are declared in a **separate npm package**: `encrypted-types@0.0.4`, authored by the Confidential Token Association — not in `@fhevm/solidity`. `FHE.sol` imports from it via `import "encrypted-types/EncryptedTypes.sol";` at the top of the file, then uses the types throughout without declaring any of them. An agent greping `FHE.sol` for type declarations will wrongly conclude the types don't exist.
>
> **Rule:** grep `node_modules/encrypted-types/EncryptedTypes.sol` for type declarations; grep `node_modules/@fhevm/solidity/lib/FHE.sol` for function declarations. Two different files, two different packages.

- **What I was trying to do:** Write `scripts/verify-env.sh` — the operational form of CR-2 — to validate that every canonical FHEVM symbol the skill references is present in the installed library. Draft assumed types and functions were both declared in `FHE.sol`.
- **What happened:** First run reported 10 MISSING for every type check (`type euint8`, `type euint32`, `type externalEuint32`, etc.), while every function check and every absence check passed. Initially looked like a script bug — all 10 failures in the same check block with identical structure is suspicious of a shared wrong assumption, not individual typos.
- **Error message:** `MISSING  type euint32 not found in FHE.sol` ×10.
- **Time wasted:** ~10 min (fast because the script's own output immediately pointed at the shared assumption — every type failed, every function succeeded, so the question was "what's different about types?").
- **Fix:** Added a second path `TYPES_SOL="$PROJECT_ROOT/node_modules/encrypted-types/EncryptedTypes.sol"` to the script and routed the type checks through it. Function checks stay on `FHEVM_SOL`. One new variable, one new check block, zero logic change.
- **Why I didn't see it coming:** I assumed symbol locality — "the FHEVM library declares its types" — which is the Solidity convention for library code (types and functions colocated). FHEVM broke this convention by consuming a third-party type package (`encrypted-types` is authored by the Confidential Token Association, not Zama). The import in `FHE.sol` is easy to miss because you read the file looking for type declarations, find function declarations using the types, and assume the types are declared elsewhere in the same file below your scroll position. They're not.
- **The meta-point this illustrates:** **The script's own CR-2 violation was caught by running the script.** This is exactly the self-referential validation the skill teaches. The author (coach + me) assumed a symbol's location based on prior intuition; grep-in-the-right-place disproved it. The skill's discipline is being enforced on its own author, which is the strongest possible validation that the discipline is worth teaching.

- **Adjacent category this opens up:** "Stale layout assumptions" — distinct from the "Stale API names" category. Stale API names are about symbols that existed but don't anymore. Stale layout assumptions are about symbols that exist but not where you thought. Both have the same corrective (grep before trust); both will catch an agent off-guard in similar ways. The skill's `anti-patterns.md` should name both categories separately.

### 2026-04-17 — Hardhat `HH411` on stale `fhevm/` imports suggests the wrong fix

> When a contract imports from `fhevm/lib/TFHE.sol` (the pre-v0.7 path), Hardhat emits `HH411: "The library fhevm, imported from ..., is not installed. Try installing it using npm."` **The suggested fix is a trap.** Running `npm install fhevm` installs the unmaintained pre-v0.7 package, which resolves the error and allows TFHE-era code to compile — but the resulting contracts use old protocol semantics that the v0.10+ coprocessor does not speak. Failure is silent: compiles cleanly, mock tests may pass, breaks against a live coprocessor.
>
> **Rule (CR-2 extension):** when a compiler or package manager suggests a fix that would *install a package*, verify against `node_modules/@fhevm/solidity/` that the suggested package is actually the canonical source, not a deprecated predecessor. **Trust the grep, not the tool's suggestion.**

- **What I was trying to do:** Mock-verify anti-pattern entry 1.4 (stale `TFHE` import) by compiling a throwaway contract using the pre-v0.7 import path and capturing the exact error string for the entry's provenance tag.
- **What happened:** Instead of a straightforward `DeclarationError: Undeclared identifier 'TFHE'` (which is what a pure Solidity compile error would look like), Hardhat itself intercepted the missing-library case and emitted `HH411` with an "install it via npm" suggestion. The verification captured not just an error string but a structurally different failure mode — tooling misdirection.
- **Error message:** `Error HH411: The library fhevm, imported from contracts/_stale_tfhe.sol, is not installed. Try installing it using npm.`
- **Time wasted:** 0 min solving (this was expected-to-fail evidence-gathering), but the discovery of the trap is the load-bearing part.
- **Fix:** Do **not** run `npm install fhevm`. Rewrite the import to `import {FHE, ...} from "@fhevm/solidity/lib/FHE.sol";` and rename `TFHE.X` → `FHE.X` throughout. Package install is not part of the fix.
- **Why I didn't see it coming:** I expected the failure mode for stale API names to be "the code doesn't compile, you get told, you fix the code." That's true for 1.5 (`einput`) and 1.6 (`ebytes32`) — both produced clean `DeclarationError` with no "helpful" suggestion. But 1.4 lives on the dependency boundary (an import from an npm package), which triggers Hardhat's resolution logic, which has its own misdirection behavior. **The error's remediation advice is generated by the tool based on what would make the error go away — not by the library based on what would be correct.** Tools optimize for "make the error disappear"; that is not the same as "use the right package."
- **Why this is a footgun for agents specifically:** An LLM reading an error message is primed to treat the suggested fix as authoritative — it's structured diagnostic output. Agents will follow `Try installing it using npm.` by default. This is the first case in this project where the *tool's own suggestion* is the trap, distinct from stale training data being the trap. CR-2 generalized: don't just grep before trusting your own priors; grep before trusting the tool's suggestions.

### 2026-04-18 — Orphan type declarations: declared in `encrypted-types` but no ops in `@fhevm/solidity`

> Types declared in `encrypted-types/EncryptedTypes.sol` are not necessarily usable. Grep found **zero** `FHE.*` operation overloads for any `eint*` (signed types, all widths), any `euint*` in the 8-bit-increment family (`euint24`, `euint40`, …, `euint248`), any `ebytes*`, and any external variant of the above. These types parse as declarations, but subsequent lines fail at Solidity compile time with unresolved-function errors.
>
> **Rule (CR-2 extension):** grep-before-trust on types must verify *op support*, not just declaration presence. The verification workflow for any type not in the canonical set must include both (a) grep the type's declaration in `EncryptedTypes.sol` and (b) grep for at least one `FHE.*` overload on that type in `FHE.sol`. Declaration presence is necessary but not sufficient.

- **What I was trying to do:** verify `euint160` op support during review of `encrypted-types.md` §4.2. The draft recommended "store as `euint160`" as a workaround for encrypted address ordering.
- **What happened:** grep for ops on `euint160` returned empty. Broadened the check to other 8-bit-increment widths, signed `eint*`, and `ebytes*` families — all returned zero. The types are declared but have no operational support in the canonical library.
- **Error mode:** any contract attempting to use these types fails at Solidity compile time with `TypeError: Member "<op>" not found or not visible` (or equivalent unresolved-function error). Not a runtime failure; the code doesn't compile.
- **Time wasted:** ~3 min on the initial `euint160` grep; the broadening to other families took another ~5 min. Net-positive — the verification caught *two* distinct factual errors in the draft (the `euint160` workaround itself, AND the op-matrix cells for `neg`/`rand` on `euint256` which the follow-up grep surfaced as a side effect).
- **Fix:** revised `encrypted-types.md` to name "orphan type declarations" as a distinct hazard category with explicit verified-orphan lists and a do-not-use directive. Rewrote §4.2 to acknowledge the library limitation honestly rather than suggest a workaround that doesn't exist.
- **Why I didn't see it coming:** my mental model for library packages was "declared → usable." In FHEVM the `encrypted-types` package is a *type declaration surface* that is wider than the `@fhevm/solidity` operation surface. The two packages are authored separately (encrypted-types by the Confidential Token Association, FHE.sol by Zama) and do not require lockstep coverage. An agent greping `EncryptedTypes.sol` sees all the declared types; an agent greping `FHE.sol` sees the usable subset. **Only the latter matters for writing code that compiles.**
- **Third-case observation (worth naming in submission README):** this is the third time in Phase 2 that the skill's own verification discipline has caught a wrong prior in the skill's own authoring. First: the `encrypted-types` package layout (types not in `@fhevm/solidity`). Second: the Hardhat HH411 trap on `fhevm/` imports. Third: orphan declarations. Three data points is enough to make the "the discipline catches its own authors" claim non-anecdotal — and that's a claim worth making in the submission, because it's evidence the skill's methodology is robust against the authors it was written by, not just the agents it was written for.

### 2026-04-19 — `cleanTransientStorage` clears ACL + input verifier transient state in one call

> Calling `FHE.cleanTransientStorage()` mid-transaction wipes both transient ACL grants **and** input verifier transient state. The bundling is not selectable — there is no public single-store cleanup function exposed. An agent calling `cleanTransientStorage` to "clean up transient ACL grants" will silently break any in-flight `FHE.fromExternal` call later in the same transaction.

- **What I was trying to do:** verify the signature and semantics of `FHE.cleanTransientStorage()` while drafting `access-control.md` §3.2.
- **What happened:** the function source revealed two internal calls bundled into one public function:
  ```solidity
  function cleanTransientStorage() internal {
      Impl.cleanTransientStorageACL();
      Impl.cleanTransientStorageInputVerifier();
  }
  ```
  No parameters. Global. Both stores cleared together; no selective cleanup function is exposed.
- **Why this is a footgun:** an agent reading the function name expects "clean up my transient ACL grants" — a reasonable interpretation of the symbol. The actual behavior also resets the input verifier's transient state, which is used by `FHE.fromExternal` to validate caller-submitted encrypted inputs against their proofs. A function that calls `allowTransient`, then does some work, then calls `cleanTransientStorage`, then calls `fromExternal` for a new input later in the same transaction will hit failures on the second `fromExternal` call that look unrelated to the cleanup. The naming hides the bundle.
- **Caught how:** while writing the `access-control.md` draft, I greped the function with `grep -nA 3 "function cleanTransientStorage"` to verify the signature. The `-A 3` revealed the two internal calls. Without the `-A 3` flag (i.e., looking only at the function declaration line), the bundle would not have surfaced — the signature alone gives no hint that input verifier state is also affected.
- **Process lesson:** when verifying a function signature for an op-heavy reference file, grep with surrounding context (`-A 3` or `-B 1 -A 5`), not just the declaration line. Function declarations describe what they're called; their bodies describe what they do. The discrepancy is the kind of detail that becomes a footgun in agent-generated code.
- **Why I didn't see it coming:** I assumed that a function named `cleanTransientStorage` would map to a single conceptual store named "transient storage" — singular. The library has *two* transient stores (ACL grants, input verifier state) and one cleanup function that addresses both. Naming asymmetry: two underlying stores, one bundled cleanup, no per-store public surface. An agent reading the name and inferring "transient storage" → "ACL grants" specifically is following a reasonable but wrong inference path.

### 2026-04-29 — `FHE.fromExternal` has two authorization paths — cryptographic proof or existing ACL

> The function `FHE.fromExternal(handle, proof)` has two paths gated on whether `proof` is empty. With a non-empty proof, `Impl.verify` checks the cryptographic binding to `(contract, sender)` — wrong combination fires `InvalidSigner()`. With an empty proof, the function checks whether `msg.sender` already has ACL on the handle — no ACL fires `SenderNotAllowedToUseHandle(handle, sender)`.
>
> The empty-proof path is **not a verification skip**. It exists for account-abstraction wallets that have already been authorized on a handle in a prior UserOp and want to re-pass it without minting a fresh proof. An agent reading code that calls `fromExternal(handle, "")` should not assume the proof was forgotten — it's a deliberate library feature.
>
> Both paths enforce the same invariant (only authorized callers can introduce a handle into a contract) via different mechanisms.

- **What I was trying to do:** capture the signature and behavior of `FHE.fromExternal` for `input-proofs.md` §2. The grep with surrounding context (`-A 6` extended to `-A 15` on follow-up) revealed the function body, not just the declaration.
- **What happened:** the function body has an `if (inputProof.length != 0) { /* cryptographic */ } else { /* ACL check */ }` structure that's not visible from the signature alone. The standard mental model — "fromExternal verifies a proof, returns a handle" — is half the story.
- **Error modes:** two distinct, distinguishable reverts:
  - `InvalidSigner()` — proof present, cryptographic verification rejected (mismatched contract OR mismatched sender, both fire the same error class).
  - `SenderNotAllowedToUseHandle(bytes32 handle, address sender)` — proof empty, sender lacks ACL on the handle.
- **Time wasted:** ~5 min on the follow-up grep + ~5 min reasoning about the AA-wallet use case before drafting. Net-positive on the credibility budget — without this finding, the draft would have characterized `fromExternal` as a single-path verification function and missed a load-bearing library feature.
- **Why I didn't see it coming:** the doc comment on `fromExternal` mentions the empty-proof path but only obliquely ("could facilitate integrating smart contract accounts with fhevm"). The mechanism — ACL check as authorization mechanism in lieu of cryptographic proof — is invisible from the signature, and the doc comment doesn't name `Impl.isAllowed` as the alternate check. The function's body had to be read directly. **Process lesson reinforced from yesterday's `cleanTransientStorage` entry: function declarations describe what they're called; their bodies describe what they do. Grep with `-A` context for any function whose behavior matters to the file being drafted.**
- **Why this is a footgun for agents:** the standard Solidity mental model for "validate-then-convert" functions has one path. An agent reading FHEVM contracts in the wild may encounter `FHE.fromExternal(handle, "")` and reach for one of two wrong inferences:
  1. "The author forgot the proof — I should add one back." (Wrong — the empty form is deliberate for AA wallets.)
  2. "Empty proof bypasses verification — this is a security hole." (Wrong — the ACL check is the authorization mechanism on this path.)
  Documenting both paths explicitly prevents both inferences.

### 2026-04-29 — `makePubliclyDecryptable` silently substitutes default values on uninitialized handles

> Calling `FHE.makePubliclyDecryptable` on a state variable that has never been written to does **not revert**. The function source begins with an `isInitialized` check that silently substitutes a type-appropriate default — `false` for `ebool`, `0` for `euint8` through `euint256`, `address(0)` for `eaddress` — and marks that default as publicly decryptable.
>
> An off-chain client decrypting the resulting handle gets the substituted zero **successfully**, with no error and no "no value yet" signal. If a contract needs to distinguish "tally was zero" from "tally was never set," the distinction must live in a separate boolean state variable; the encrypted handle alone cannot carry it.

- **What I was trying to do:** capture the signature of `FHE.makePubliclyDecryptable` while drafting `decryption.md` §2. Standard middle-path: grep with surrounding context (`-A 4`) to see the body, not just the declaration line.
- **What happened:** the function source revealed an `if (!isInitialized(value)) { value = asEXX(...); }` substitution at the top of every overload. The substitution is invisible from the declaration line; only the body shows it.
- **Error mode:** none — and that's the footgun. There's no error to surface. The function succeeds, the off-chain client decrypts to the type's zero value, and the contract / caller receives a plaintext that *looks like* a real result.
- **Time wasted:** ~3 min on the grep + ~5 min on reasoning about the implications. Net-positive — without this finding, `decryption.md` §2 would have characterized `makePubliclyDecryptable` as "marks the handle for public decryption" without the silent-default footnote, and an agent generating "reveal this tally before any votes" code would silently expose decrypted-zero with no error path to flag the issue.
- **Fix:** documented inline in `decryption.md` §2.3 with the explicit substitution table per type and the contract-design rule "track 'value was set' separately if the distinction matters." Same discipline as `cleanTransientStorage` — name the bundled / silent / default-handling behavior so an agent doesn't infer "no error = correct result."
- **Why I didn't see it coming:** standard Solidity functions either succeed with the requested behavior or revert. "Succeeds with substituted-default behavior" is a third path that's not part of the standard mental model. The function's name (`makePubliclyDecryptable`) describes the intent; the body's substitution describes a defensive fallback that the name doesn't disclose.
- **Process lesson reinforced:** **function declarations describe what they're called; their bodies describe what they do.** Same pattern as the `cleanTransientStorage` finding (declaration says "clean transient storage"; body clears two distinct stores) and the `fromExternal` dual-path finding (declaration says "convert external to internal"; body has two authorization paths). Three findings across three reference files where the body diverged from the declaration's implication, all caught by `grep -A N` instead of just `grep`. The N matters; default `grep` shows the declaration only.

