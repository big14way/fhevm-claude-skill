# Zama FHEVM Skill — Architecture

## Frame

The skill is three layers of defense against wrong generation, not a tutorial.

  Layer 1 — REFUSE: name specifically-wrong patterns and instruct the agent
    to refuse to generate them. This is where training-data staleness gets
    intercepted. Concrete anti-pattern list.

  Layer 2 — VERIFY: require grep-against-installed-library before trusting
    any FHEVM symbol. This catches stale priors the anti-pattern list missed
    and makes the skill robust against v0.12+ library changes.

  Layer 3 — GENERATE: once refused-patterns and verification are clear, the
    agent produces code from a small set of correct templates and rules.
    Terse, not tutorial.

The skill is a router. The SKILL.md file contains: frontmatter, the three
layers as a compressed checklist, and pointers to reference files. The
reference files contain the detailed content. Scripts automate the
verification layer. This keeps SKILL.md under ~400 lines and loadable into
context cheaply.


## SKILL.md top-level structure

  frontmatter:
    name: zama-fhevm
    description: {assertive one-liner — trigger condition for the agent}

  § When to use this skill
    {3-5 trigger phrases}

  § Before you write any code — verification gate
    Run: bash scripts/verify-env.sh
    This confirms package versions + greps expected symbols. If it fails,
    stop and report; do not guess at API names.

  § Refused patterns (NEVER generate these)
    Compressed list of ~6-8 anti-patterns with one-line reason each.
    Points to references/anti-patterns.md for detail.

  § Core rules (always follow)
    The three CORE rules from your audit, compressed.
    Points to references/core-rules.md for detail.

  § Writing a new FHEVM contract
    Step-by-step workflow. Points to templates/ and references/ as needed.

  § Writing tests for an FHEVM contract
    Step-by-step. Emphasizes sequential awaits + bigint assertions.
    Points to references/testing.md and templates/Contract.test.ts.

  § Troubleshooting
    Symptom → likely cause → fix. Covers the top 6-8 errors.
    Points to references/troubleshooting.md.


## references/ — detailed content the agent loads on demand

  references/anti-patterns.md
    Full list of removed/renamed/wrong APIs with:
      - what the agent might generate
      - why it's wrong (version it was removed, what replaced it)
      - the correct v0.11 equivalent
    Organized by category: decryption, config imports, test concurrency,
    assertion types, ACL assumptions, branching.

  references/core-rules.md
    The three CORE rules expanded:
      CR-1 handle mutation and per-handle ACL
      CR-2 grep-before-trust
      CR-3 sequential awaits on decrypt

  references/encrypted-types.md
    euint8/16/32/64/128/256, ebool, eaddress — when to use each.
    Range and operation support table.
    Explicit note: euint256 has limited op support; prefer smaller types
    when arithmetic is needed.

  references/operations.md
    Arithmetic, comparison, logical. FHE.select pattern for branching.
    Explicit refusal: if (encryptedCondition) is impossible; use FHE.select.
    {content partially sourced from docs; validated by demo contract}

  references/access-control.md
    allow / allowThis / allowTransient / isSenderAllowed.
    Decision tree: when to use each.
    The "ACL follows handle production, not data contribution" rule.

  references/input-proofs.md
    externalEuintXX + inputProof pattern.
    Relayer SDK usage for producing encrypted inputs from frontend.
    Mock-mode equivalent using fhevm.createEncryptedInput.

  references/decryption.md
    Two patterns: user decryption and public decryption.
    v0.11 API — makePubliclyDecryptable + off-chain via relayer.
    Explicit refusal of the pre-v0.9 requestDecryption/Gateway pattern.
    Sepolia-vs-mock caveats labeled.

  references/frontend-integration.md
    @zama-fhe/relayer-sdk: createInstance, encrypt, publicDecrypt,
    userDecrypt (EIP-712 signed).
    React patterns — provider, hooks, wallet integration.
    {sourced from docs + @zama-ai/fhevm-react-template}

  references/testing.md
    Hardhat plugin: fhevm.createEncryptedInput, publicDecryptEuint,
    userDecryptEuint.
    Sequential await rule (CR-3) with the Promise.all counter-example.
    bigint assertion rule with the .to.eq(5n) example.
    Mock vs Sepolia labeling discipline.

  references/troubleshooting.md
    Top errors with cause → fix:
      - "ACL not allowed" → forgot re-grant after op
      - Internal mock cursor error → Promise.all on decrypts
      - Silent assertion failure → number vs bigint
      - Compile error on FHE.requestDecryption → stale API
      - Compile error on SepoliaConfig import → use ZamaEthereumConfig
      - Revert on externalEuint → bad inputProof binding


## templates/ — starting points the agent copies from

  templates/Contract.sol
    Minimal v0.11-correct boilerplate: imports, ZamaEthereumConfig,
    constructor with initialization + allowThis + owner ACL,
    one increment-style function showing fromExternal + op + re-grant,
    one getter with ACL check.
    Heavily commented with pointers to references/.

  templates/Contract.test.ts
    Hardhat-plugin test file with:
      - proper fhevm.createEncryptedInput setup
      - sequential await pattern for decrypts
      - bigint assertions
      - one user-decrypt example
      - one public-decrypt example

  templates/frontend.tsx
    React component with relayer-sdk instance, encrypt-input example,
    one public-decrypt and one user-decrypt flow.


## scripts/ — automated verification the agent invokes

  scripts/verify-env.sh
    Checks:
      - node --version >= 20 (even)
      - @fhevm/solidity installed, version printed
      - @fhevm/hardhat-plugin installed, version printed
      - greps for: makePubliclyDecryptable, fromExternal, allowThis,
        checkSignatures, ZamaEthereumConfig
      - greps for absence of: requestDecryption, SepoliaConfig (warns if
        present in user code — may be stale example)
    Exits non-zero if anything required is missing.
    Output is terse: VERIFIED / MISSING per check.

  scripts/lint-antipatterns.js
    Static scan of user's contracts/ directory for:
      - if (e<anything>) — likely branching on encrypted
      - FHE.requestDecryption — stale API
      - SepoliaConfig — stale config
      - FHE.add/sub/mul/div/rem without matching FHE.allowThis on the
        resulting assignment line (± 3 lines)
    Output: file:line — pattern — suggested fix.
    Best-effort, not proof — noted as such in its own doc comment.

  scripts/check-acl.js
    Heuristic: for every state variable of type euint*/ebool/eaddress,
    flag any function that writes to it without a subsequent
    FHE.allowThis(stateVar).
    Same "best-effort, review output" caveat.


## process/ — for the author, not agent-facing

  PROCESS_NOTES.md stays in its current form: workspace decisions,
  prediction-before-code methodology, two-level reasoning. Not referenced
  from SKILL.md.


## What this architecture leaves out deliberately

  - No "Intro to FHE" prose. The agent does not need a conceptual primer;
    it needs operational rules. Zama's docs explain FHE for humans.
  - No marketing section. "Why FHEVM is great" has zero points on the rubric.
  - No exhaustive type table repeated inline — it lives in one reference
    file and is pointed to.
  - No long example-driven tutorial. Examples live in templates/ and the
    demo repo, not in the skill file.

## Open questions for merge

  Q1 Does the three-layer frame (REFUSE/VERIFY/GENERATE) land as the
     structural backbone, or does it feel forced?
  Q2 Is scripts/lint-antipatterns.js a good investment of time, or does its
     best-effort nature make it noise?
  Q3 Should references/frontend-integration.md be merged into the demo
     repo README instead of the skill itself? (It's Phase 3 content.)
  Q4 Any CORE/ANTI-PATTERN from your audit that doesn't fit a section?
