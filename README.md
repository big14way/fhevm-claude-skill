# FHEVM Claude Skill

A [Claude Code](https://docs.claude.com/en/docs/claude-code) skill for writing, testing, and deploying confidential smart contracts with Zama's [FHEVM](https://github.com/zama-ai/fhevm).

**Submission for the [Zama Developer Program Mainnet Season 2](https://www.zama.org/post/zama-developer-program-mainnet-season-2-confidential-finance-is-the-next-frontier) — Bounty Track (AI Agent Skills for FHE).**

---

## What this skill does

When loaded into Claude Code, this skill enables an AI agent to accurately write, test, and deploy confidential smart contracts using FHEVM. It targets `@fhevm/solidity ≥0.10` and `@fhevm/hardhat-plugin ≥0.4`.

The skill is structured as **three layers of defense against wrong generation**, not as a tutorial:

1. **Refuse** — explicit anti-patterns the agent never generates, with version-specific framing (e.g., the pre-v0.9 `requestDecryption` API, removed but still in LLM training data).
2. **Verify** — `scripts/verify-env.sh` runs at session start to ground every API claim against the installed library, replacing trust in priors with trust in the filesystem.
3. **Generate** — once refusals and verification are in place, the agent produces code from a small set of correct templates and rules.

The leverage is at the interception point. An agent without this skill writes plausible-looking FHEVM code that fails to compile (because of stale APIs), compiles but fails silently (because of missing ACL re-grants), or compiles and runs but leaks confidentiality (because of subtle ACL pattern errors). This skill is designed to prevent each of these failure modes by name.

---

## Quick start

```bash
git clone https://github.com/big14way/fhevm-claude-skill.git
cd fhevm-claude-skill/skill
```

Point Claude Code at the `skill/` directory. From within a Hardhat project that has `@fhevm/solidity` and `@fhevm/hardhat-plugin` installed:

```bash
bash skill/scripts/verify-env.sh
```

If verify-env.sh exits non-zero, stop and resolve the missing items before writing FHEVM code. The script is the operational form of the skill's CR-2 rule (grep-before-trust); a clean run is the precondition for everything that follows.

---

## Structure

```
skill/
├── SKILL.md                          # router; loaded first by Claude Code
├── references/
│   ├── core-rules.md                 # CR-1 (per-handle ACL), CR-2 (grep-before-trust), CR-3 (sequential decrypts)
│   ├── anti-patterns.md              # patterns the agent must refuse to generate
│   ├── encrypted-types.md            # type selection, op-support matrix, orphan-declaration hazards
│   ├── operations.md                 # composition idioms, cross-cutting rules
│   ├── access-control.md             # ACL grants, decision tree, the per-voter / aggregate leak
│   ├── input-proofs.md               # encrypted-input round-trip, the dual-path verification surface
│   ├── decryption.md                 # public, user, and delegated decryption flows
│   ├── frontend-integration.md       # relayer SDK init, wallet integration, React patterns
│   ├── testing.md                    # @fhevm/hardhat-plugin patterns
│   └── troubleshooting.md            # error catalog and triage
├── scripts/
│   ├── verify-env.sh                 # the VERIFY layer
│   └── lint-antipatterns.js          # substring scan for refused patterns
└── templates/
    ├── Contract.sol                  # v0.10+-correct boilerplate
    └── Contract.test.ts              # paired hardhat-plugin test template
```

The repo also includes `FOOTGUN_LOG.md` and `PROCESS_NOTES.md` at the top level — see the next section.

---

## How this skill was built — the verification record

The skill's reference files contain inline provenance tags on every behavioral claim:

- `[mock-verified YYYY-MM-DD]` — confirmed by running tests against `@fhevm/hardhat-plugin` mock mode on the stated date
- `[grep-verified]` — confirmed by greping `node_modules/@fhevm/solidity/lib/FHE.sol` or related installed source
- `[compile-verified YYYY-MM-DD]` — confirmed by compiling code examples against the current library
- `[docs-sourced]` — taken from Zama documentation
- `[reasoned]` — inferred from other verified facts; tagged so reviewers know which claims have which epistemic status

Every claim in the skill carries one of these tags or descends from a section header that does.

The `FOOTGUN_LOG.md` file at the top level captures the substantive findings made during drafting — including three load-bearing corrections that came from greping the installed library at the moment of inference rather than reasoning from priors. These entries are the raw record:

- The pre-v0.9 `requestDecryption` API was removed in v0.9, but most LLM training data predates the change. Documented as the headline anti-pattern.
- `FHE.fromExternal` has two authorization paths (cryptographic proof and existing ACL), not one. Documented in `input-proofs.md`.
- 8-bit-increment encrypted-integer types (`euint24`, `euint40`, etc.) are *declared* in `encrypted-types/EncryptedTypes.sol` but have *no operation overloads* in `@fhevm/solidity` — they parse but cannot be used. Documented in `encrypted-types.md` as the orphan-declaration hazard category.

The `PROCESS_NOTES.md` file captures authorial discipline observations, including the front-load-grep-verification pattern that surfaced these corrections before they shipped as wrong claims.

---

## Demo

A working confidential application built using the skill lives at [`demo/`](./demo/) — a sealed-bid auction where three bidders submit encrypted bids, the admin reveals only the winning amount, and losing bids stay encrypted forever. Seven mock-mode tests pass; the contract is structured to deploy to Sepolia without changes.

The demo exercises the skill's load-bearing patterns end-to-end: per-bidder ACL with aggregate-revealed-via-public-decrypt (the canonical leak prevention from `skill/references/access-control.md` §4), encrypted comparison via `FHE.gt` + `FHE.select` (from `skill/references/operations.md` §2.4), and deadline-gated public decryption (from `skill/references/decryption.md` §2). See [`demo/README.md`](./demo/README.md) for the full walkthrough.

### Demo video

[https://youtu.be/jNose-JBnxA?si=2DchEkEpZjDQAAgv.] A short screen recording shows Claude Code, with this skill loaded, producing a working confidential FHEVM application from a natural-language prompt — including contract, tests, and a clean run against the mock coprocessor.

---

## Compatibility

| Component | Version |
|---|---|
| `@fhevm/solidity` | ≥0.10 |
| `@fhevm/hardhat-plugin` | ≥0.4 |
| `@zama-fhe/relayer-sdk` | ≥0.4 |
| Solidity | ^0.8.24 with `evmVersion: "cancun"` |
| Node.js | ≥20 (even-numbered majors only — Hardhat does not support odd) |

`verify-env.sh` checks all of the above before any work begins.

---

## License

MIT. See `LICENSE`.

The skill targets the Zama Protocol and the FHEVM library, both of which carry their own licenses. This skill is operational documentation and tooling — it does not redistribute Zama's library code.

---

## Author

Godswill Idolor Eseteru ([@big14way](https://x.com/big14way)) — Lagos, Nigeria.

Built April 2026 for the Zama Developer Program Mainnet Season 2 Bounty Track. Submission deadline May 10, 2026.
