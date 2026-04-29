# Skill Outline — Log Audit & Categorization

Phase 2, step 1. Every entry in `FOOTGUN_LOG.md` mapped to tags and an agent-facing lesson.

**Tag legend:**
- **CORE** — rule the agent must always follow
- **ANTI-PATTERN** — something the agent will generate wrong based on stale priors
- **VERIFICATION** — workflow the agent should do before trusting something
- **GOTCHA** — technical detail that doesn't fit the above but burns time
- **CONCEPTUAL** — mental model correction

**Agent-facing lesson vs. log entry:** the log says "here's what tripped me." The lesson is "here's the instruction for the agent so it doesn't trip here." The lesson is imperative, short, prescriptive — not an explanation.

---

## The table

| # | Entry (short title) | Tag(s) | Agent-facing lesson |
|---|---|---|---|
| 1 | `SepoliaConfig` import does not exist | ANTI-PATTERN, VERIFICATION | Import `ZamaEthereumConfig` from `@fhevm/solidity/config/ZamaConfig.sol` — not `SepoliaConfig`, `MainnetConfig`, or any other per-network name. The library consolidated per-network configs into a single contract regardless of target. When an import name comes from a doc or tutorial you haven't used in this repo, grep `node_modules/@fhevm/solidity/` to confirm before writing the import. |
| 2 | ACL follows handle production, not data contribution | CORE, CONCEPTUAL | The producer of a new encrypted handle — the contract calling `FHE.add` / `FHE.sub` / `FHE.select` / `FHE.fromExternal` — is the only party with ACL on that handle unless it explicitly grants. Callers who submit encrypted inputs get transient contract-only access; they never receive read rights on derived state. After every op that produces or mutates an encrypted value, explicitly grant ACL via `FHE.allowThis(handle)` and `FHE.allow(handle, addr)` for every address that needs to read the result. Inputs are write-only by default. |
| 3 | Delete-and-replace when test semantics change | GOTCHA | When a test's assertion flips meaning (revert-expected → success-expected, or vice versa), delete the test and write a new one with a name that matches the new behavior. Never mutate a test body while keeping the old descriptive name. In FHEVM suites test names encode ACL expectations; a test named "X reverts for non-owner" that actually asserts success is a time bomb for anyone reasoning about the contract's guarantees. |
| 4 | Trivial-encryption decrypts identically to op results (mock) | GOTCHA, VERIFICATION | In mock mode, a handle from `FHE.asEuint32(0)` decrypts identically to a handle from `FHE.add` / `FHE.sub` / etc., via both `userDecryptEuint` and `publicDecryptEuint`. This parity is **verified only in mock** — not on live Sepolia. When porting to production, re-test initial/zero encrypted state explicitly rather than assuming the mock's behavior transfers. |
| 5 | Meta-note: the right test for a conceptual footgun (METHOD) | — (process, not agent-facing) | Not an agent instruction. This is a skill-authoring rule: include a lesson in the skill if standard Solidity/EVM intuition would produce the wrong answer, not just when a particular human was confused. Belongs in `PROCESS_NOTES.md` or a "how this skill was built" appendix, not the agent-facing skill body. |
| 6 | HEADLINE: pre-v0.9 decryption API is gone | ANTI-PATTERN, VERIFICATION, CORE | Do not generate `FHE.requestDecryption`, `DecryptionOracle`, `Gateway.sol`, `GatewayCaller`, or `onDecryptionResult`-style callback patterns — these were removed in FHEVM v0.9 and do not exist in `@fhevm/solidity` v0.10+. For public reveal in v0.11, call `FHE.makePubliclyDecryptable(handle)` on the current encrypted value; plaintext is then accessible off-chain via the relayer (`fhevm.publicDecryptEuint` in tests, `relayer-sdk` in frontends). Before using any FHEVM symbol not already used in this repo, grep `node_modules/@fhevm/solidity/lib/FHE.sol` — if the symbol is absent, the code will not compile no matter how idiomatic it looks in older tutorials. |
| 7 | `publicDecryptEuint` (and siblings) returns `bigint`, not `number` | GOTCHA | Every `fhevm.userDecryptEuint`, `fhevm.publicDecryptEuint`, and ethers v6 `uint*` getter returns JavaScript `bigint` — not `number` — regardless of the Solidity source type's range. Write test assertions as `.to.eq(5n)` with the `n` suffix, or wrap numeric expected values in `BigInt(...)`. Chai's strict equality silently fails on `bigint != number`. First debugging step when you see `expected 5n to equal 5` is to check assertion types, not the contract. |
| 8 | PROSPECTIVE: predictions for ConfidentialVote (before coding) | — (process, not agent-facing as-is) | Not a rule per se; carries a secondary meta-instruction worth including: before implementing a new FHEVM contract, explicitly list 1–2 failure modes you expect based on ACL, handle mutation, and tooling gotchas, and compare to reality afterward. This disciplines the coding and produces retrospective material. More a skill-authoring practice than an agent-execution rule. |
| 9 | `Promise.all` of parallel decrypts races the mock coprocessor | ANTI-PATTERN, CORE | Always `await` `fhevm.publicDecryptEuint` / `userDecryptEuint` calls sequentially in tests. Never use `Promise.all([...decrypt calls])` even when the handles are independent — the mock coprocessor's `BlockLogCursor` is not concurrency-safe and will throw `Parse event at blockNumber=N, logIndex=M in backward order` once test event volume accumulates. The failure manifests as a flake (passes on small inputs, fails on larger) and the stack points inside `node_modules/@fhevm/mock-utils/`, not the test. When you see that stack, suspect the `Promise.all` wrapper first. |
| 10 | RETROSPECTIVE: predictions vs. reality for the vote round | — (process, not agent-facing as-is) | Not directly an agent instruction. Carries a meta-observation for the skill's "how to think about FHEVM failures" section: reason at two levels — the protocol (ACL, handles, encrypted types) and the tooling (plugin/mock/relayer behavior). The most non-obvious failures live at the tooling layer because they don't appear in any public type signature. |

---

## Cross-cutting lessons that emerge from multiple entries

These weren't individual log entries but recur across several and deserve standalone treatment in the skill:

### CC-A: "Grep the installed library before trusting a symbol name" — CORE, VERIFICATION
Appears in entries 1 and 6. Both footguns were caught by the same workflow: when I hit an unfamiliar FHEVM symbol (whether in a scaffold, a tutorial, or an LLM-generated suggestion), I grepped `node_modules/@fhevm/solidity/` before using it. If the grep returns nothing, the symbol is stale and the code will not compile. This is probably the single most valuable workflow in the entire skill — it would have caught both the `SepoliaConfig` and the `requestDecryption` footguns with one `grep -rn` each. Deserves its own short section with the exact commands.

### CC-B: "Mock ≠ live chain; verified-in-mock is a local claim" — GOTCHA, VERIFICATION
Appears in entries 4 and 9. The mock plugin is extremely useful but has its own constraints (the cursor race) and its own lies-of-omission (possible trivial-encryption short-circuits). Whenever a claim is verified only in `fhevm.isMock` mode, label it as such, and re-verify on live Sepolia before trusting it in production code. This is a habit of mind the skill should instill: *don't generalize from mock behavior to protocol behavior without evidence.*

### CC-C: "Handles mutate per op; ACL is per-handle, not per-variable" — CORE, CONCEPTUAL
Appears implicitly in entries 2, 8 (prediction 1), and 10. The rule is: any state-producing operation (`FHE.add`, `FHE.sub`, `FHE.select`, `FHE.fromExternal`) produces a *new* handle; the old handle's ACL does not propagate. Variables in Solidity are names for storage slots; the thing that actually carries ACL is the handle *currently stored in that slot*. After every op, re-grant `allowThis` (and any user grants) on the new handle. This is the single most common mistake an agent will make if it mentally treats `euint32` like a regular Solidity `uint32`.

### CC-D: "Agents have predictable stale priors; verify before trusting your own instinct" — ANTI-PATTERN, VERIFICATION
Appears across entries 1, 5, 6. The pattern: model training data is heavy on pre-v0.9 FHEVM content, so Claude (and any other agent) will by default generate code using `requestDecryption`, `SepoliaConfig`, `Gateway`, etc. The fix is not "know better" (impossible — the prior is baked in) but "verify by grepping the installed library before committing to any FHEVM API name." This is the same CORE workflow as CC-A, but framed from the agent's perspective: *your training data is stale; treat every unfamiliar symbol as a claim to verify, not a fact.*

---

## Entries that do NOT cleanly fit the user's five buckets

Flagging these for the merge step — they may need new tags or new skill sections:

- **#3 (Delete-and-replace tests)** — it's a testing hygiene rule, not strictly FHEVM. Tagged GOTCHA as the least-wrong fit, but it might belong in a "testing patterns for confidential contracts" section rather than the core FHEVM anti-patterns. It matters more in FHEVM than in general because test names encode ACL expectations, but the rule itself is language-agnostic.
- **#5, #8, #10** — process/methodology entries that describe how I wrote the log, not how the agent should write FHEVM. Lessons derivable from them are *meta-skills* (predict failures before coding; reason at two levels; criterion for what to include). These may warrant a short "how to think" section at the front of the skill, or they may be deliberately excluded as too meta for agent-execution instructions. **Flag for merge: do we want meta-instructions in the skill, or is the skill strictly operational?**

---

## Observations on density and balance

- **ANTI-PATTERN entries dominate the highest-value slots.** Entries 1, 6, 9 — three of the most valuable — are all cases where the agent's default/idiomatic pattern is wrong. The skill's primary job seems to be *blocking* wrong generation, not *producing* right generation. Right generation can flow from the type system and the reference contract; wrong generation has to be named and refused.
- **CORE rules are few but load-bearing.** Really only CC-C (handle mutation / per-handle ACL), CC-A (grep before trust), and #2 (ACL follows production not contribution, which is really a framing of CC-C). Three rules. If an agent internalizes these three, most of the rest of the footguns don't bite or are easy to recover from.
- **VERIFICATION is understaffed in the raw log.** Only two entries explicitly verify anything (4, and the grep workflow embedded in 1/6). The skill should probably over-represent verification relative to the log, because verification is the defense against the stale-prior problem — and the stale-prior problem is the dominant failure mode.
- **No entries yet for encrypted comparisons / `FHE.select` / branchless patterns.** The counter only did add/sub; the vote only did add. We never hit `FHE.gt` / `FHE.select` because the vote spec's branching on plaintext candidate index avoided it. That's a gap in both the log and (therefore) the skill. Worth flagging — the skill should either include a lesson on encrypted comparison patterns even without a log entry, or we should queue a small example that exercises them.
- **No entries for `HCU` (homomorphic compute units) / gas-model surprises.** Another gap. I never ran out of HCU or hit a transaction-cost surprise; mock mode may paper over this. If the skill omits HCU guidance and an agent writes a loop that blows the HCU budget on live Sepolia, the failure would be non-obvious. Flag for merge: do we include HCU guidance from docs rather than from experience?

---

## Summary for the merge

**10 log entries → 7 distinct agent-facing lessons (entries 5, 8, 10 are process-only).** Plus four cross-cutting lessons (CC-A through CC-D) that emerge from multiple entries.

**Three CORE rules the skill must name and enforce:**
1. Handle mutates per op; re-grant ACL per handle (CC-C).
2. Grep the installed library before trusting any FHEVM symbol name (CC-A).
3. Sequential awaits for all fhevm decrypt calls in tests (entry 9).

**Four ANTI-PATTERNS the skill must name and refuse to generate:**
1. `FHE.requestDecryption` / `DecryptionOracle` / `Gateway.sol` / `onDecryptionResult` (entry 6).
2. `SepoliaConfig` / per-network config imports (entry 1).
3. `Promise.all` wrapping fhevm decrypt calls (entry 9).
4. `.to.eq(number)` for chai assertions on decrypt results (entry 7).

**Known gaps to surface at merge:**
- Encrypted comparisons / `FHE.select` / branchless patterns — no log entry.
- HCU / homomorphic compute budget — no log entry.
- Sepolia vs. mock divergence — log has caveats but no hands-on verification.

**Process question for the merge:** do we include meta-instructions (predict-before-code, reason-at-two-levels) in the agent-facing skill, or keep the skill strictly operational and park those in `PROCESS_NOTES.md`?
