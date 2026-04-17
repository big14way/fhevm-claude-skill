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

