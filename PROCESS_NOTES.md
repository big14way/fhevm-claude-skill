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
