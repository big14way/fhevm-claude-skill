# Process Notes

Workflow, collaboration, and project-structure decisions. Separate from `FOOTGUN_LOG.md` which is strictly FHEVM-technical.

When we write the skill's "How to structure an FHEVM project" section, lift from here.

---

## Entries

### 2026-04-17 — Workspace structure: two-tier repo

**Decision:** The workspace uses two independent git repos.

- **Outer repo** at `zama-bounty/` — tracks process artifacts: `FOOTGUN_LOG.md`, `PROCESS_NOTES.md`, future skill drafts, the final submission bundle. `.gitignore` excludes `learning/` so the nested code repo isn't double-tracked. This repo probably never gets published — it's a personal process record.
- **Inner repo** at `zama-bounty/learning/` — tracks code: Solidity contracts, TypeScript tests, Hardhat config. May get published as a reference repo linked from the submission, or stay private. Its git history stays focused on code.

**How it came up:** After I (the assistant) added the headline anti-pattern entry to `FOOTGUN_LOG.md`, I went to `git commit` it and realized the log lives at `zama-bounty/FOOTGUN_LOG.md` — *outside* the `learning/` repo. I speculatively ran `git init` at the outer level, then stopped and escalated three framed options to the coach.

**The three options considered:**
1. **Keep the speculative outer repo.** Two-tier structure: outer tracks log + workspace artifacts, inner tracks code. Outer `.gitignore` excludes `learning/` to prevent double-tracking.
2. **Roll back the outer `git init`** and **move the log into `learning/`.** One repo, log becomes part of code-repo history. Loses the "log is a separate concern" hygiene we set up on Day 1.
3. **Roll back** and leave the log untracked. Simplest, but loses versioning on the most valuable project artifact.

**Why #1 won:**
- The log is the project's most valuable artifact (per the coach's stated framing: *"the log is the real deliverable of Phase 1"*). It needs to be versioned.
- The log's value comes from being a *raw, unpolished* record. Embedding it in a code repo that may get published creates implicit pressure to clean it up for public consumption. Separation removes that pressure.
- The code repo (`learning/`) has a separate life — it may be published, forked, or discarded. Its history should be code-focused, not polluted with learning-process artifacts that don't help a reader understand the contracts.
- Double-tracking is easy to avoid with a one-line `.gitignore` at the outer level.

**Operational details:**
- Outer repo initialized at `zama-bounty/`; first commit = `workspace: initial log and gitignore`.
- `.gitignore` at outer level contains just: `learning/`
- Inner repo at `zama-bounty/learning/` continues unchanged, independent `.git/`.
- `cd` between directories to scope git operations correctly — each repo's `.git` is found via the usual parent-directory walk.

**General principle this encodes:** *Separate narrative artifacts from the production code they describe.* When a log/notes file serves a different audience, purpose, or lifecycle than the code it annotates, put it in a separate repo. The inconvenience of two repos is small; the quality degradation of a contaminated narrative is large.

**Meta-note on the escalation behavior:** The right move when a side-effect exceeds scope is (a) take the reversible action if it lets you see the problem more clearly, (b) stop before it calcifies into state that's hard to undo (like commits), (c) frame the decision as options with a recommendation. The pattern worked here: one speculative `git init`, zero speculative commits, three clean options presented.

### 2026-04-18 — Process adjustment for op/API-heavy reference files

Two consecutive files (`anti-patterns.md` entry 1.4's `euint160` workaround, `encrypted-types.md` op matrix) shipped drafts with factual errors about the FHEVM library that only review caught. Pattern: reasoning from priors without greping.

**Middle-path adjustment going forward:**

- **Op/API-heavy files** (`operations.md`, `access-control.md`, `input-proofs.md`, `decryption.md`): grep every documented API before drafting prose; compile every code example in `learning/` sandbox before including; tag claims `grep-verified` / `compile-verified` / `reasoned` in the draft so review can focus on reasoned claims.
- **Lighter files** (`frontend-integration.md`, `testing.md`, `troubleshooting.md`): current cadence.

**Trade-off:** ~20–30 min extra per heavy file, in exchange for fewer revision rounds and higher factual baseline.

**Why this adjustment matters for the skill's credibility budget:** every factual error that reaches the review stage is a cost paid by both sides — reviewer time to catch it, author time to revise, and an incremental risk that one slips through. Front-loading verification on files where API specificity is the content trades cheap upfront grep-work for expensive downstream cleanup. The heavy/light split is deliberate: files dominated by conceptual material (testing patterns, troubleshooting trees, frontend orientation) are not verification-dense in the same way, and applying the heavier discipline there would be over-engineered.

### 2026-04-29 — Front-load grep verification: the catch-rate pattern

Three substantive findings during Phase 2 reference drafting were "reasoned forward" claims that grep disproved before they shipped:

1. **`fromExternal` verifies a proof** — actually has dual paths (cryptographic proof OR existing ACL). Caught while drafting `input-proofs.md`.
2. **8-bit-increment `euint*` widths are usable** — actually orphan declarations with zero op overloads. Caught while drafting `encrypted-types.md`.
3. **Delegate uses standard `userDecrypt`** — actually a parallel SDK surface (`delegatedUserDecrypt` with both addresses explicit). Caught while drafting `decryption.md`.

Each was caught by greping the installed library *at the moment of inference*, before the prose was written. Pattern: any time the next sentence would describe an FHEVM symbol's behavior the author hasn't directly touched, grep first.

**The discipline is asymmetric in cost.** Grep takes seconds; revising a shipped wrong claim costs a review round and a credibility tax. Adopting "grep before any reasoned claim about a symbol" as a default catches this class without slowing other parts of drafting.

This is **not a footgun about FHEVM** — it's an authorial discipline note about working with libraries an LLM has stale priors on. Belongs in PROCESS_NOTES, not FOOTGUN_LOG. The three corrections themselves landed as their own footgun entries (`fromExternal` dual-path, orphan declarations, none for #3 because the catch happened pre-draft and didn't ship a wrong claim).

**Operational rule:** if the next sentence I'm about to write asserts a behavior of a function I haven't personally compiled or tested, grep `node_modules/@fhevm/solidity/lib/FHE.sol` (or the relevant SDK `.d.ts`) for that function name and read the surrounding context before continuing the sentence. The seconds spent are paid back the first time it catches a wrong claim — and across this project's history so far, three out of three "verification at the moment of inference" sorties have caught real wrong claims.

### 2026-04-29 — Standing rule: additive-only on public branches

Once a commit is on a public branch, history is not rewritten. Mistakes are fixed by additive commits.

**Rationale:** rewriting freshly-pushed public history is not just an ad-hoc-pattern problem, it's a trust signal problem. Force-pushing over the initial state of a public submission repo would look weirder than any artifact ever could. Anyone forking, watching, or auditing the history needs the history to be stable.

**Precedent:** adopted 2026-04-29 after the `NEXT.md` content remained in commit `a971b6a`'s diff after we untracked the file. Decided to leave the history alone; the content was benign and additive cleanup (the index removal and gitignore in `fad03e1`) was the correct path forward. Standing rule emerged from that decision.

**Practical application:** if a public commit shipped wrong content, the fix is a follow-up commit (correction, retraction, or replacement), never a force-push or `filter-branch`. PROCESS_NOTES and FOOTGUN_LOG entries that recharacterize prior commits are the right tool when a narrative correction is needed without a code change.

**Scope:** applies once a commit has been pushed to `origin/main` (or any public branch). Local-only history can still be reorganized via rebase or amend before the first push. The line is the push, not the commit.
