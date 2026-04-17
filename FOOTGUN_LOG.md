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

