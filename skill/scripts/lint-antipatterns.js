#!/usr/bin/env node
//
// scripts/lint-antipatterns.js — substring scan for the four refused FHEVM patterns.
//
// Run from the project root:
//   node skill/scripts/lint-antipatterns.js
//
// Scans `contracts/` and `test/` for the four refused patterns documented in
// references/anti-patterns.md and references/core-rules.md:
//
//   1. FHE.requestDecryption        — pre-v0.9 API, removed in v0.9 consolidation.
//   2. DecryptionOracle / GatewayCaller / onDecryptionResult — same era removal.
//   3. import { SepoliaConfig       — pre-v0.10 per-network config import.
//   4. Promise.all near *DecryptE*  — mock-coprocessor cursor race (CR-3).
//
// Reports `file:line  pattern` and a one-line fix per match. Exits non-zero
// on any match. Best-effort substring/regex; not AST analysis. False positives
// are possible (e.g., a comment that mentions `FHE.requestDecryption` by name
// will trigger). Treat output as a starting point for review, not proof.
//
// Why these four specifically: each is a pattern the agent's training data
// will produce by default but that does not work against the current library.
// The lint is the residual safety net after the skill's prose has told the
// agent to refuse them.

const fs = require("fs");
const path = require("path");

const PATTERNS = [
  {
    name: "pre-v0.9 FHE.requestDecryption",
    test: (line) => line.includes("FHE.requestDecryption"),
    fix: "removed in v0.9; use FHE.makePubliclyDecryptable + off-chain relayer decryption (see references/anti-patterns.md §1.1)",
  },
  {
    name: "pre-v0.9 DecryptionOracle / GatewayCaller / onDecryptionResult",
    test: (line) =>
      line.includes("DecryptionOracle") ||
      line.includes("GatewayCaller") ||
      line.includes("onDecryptionResult"),
    fix: "removed in v0.9; no inheritance needed for decryption in v0.10+ (see references/anti-patterns.md §1.2)",
  },
  {
    name: "pre-v0.10 SepoliaConfig import",
    test: (line) => line.includes("import {SepoliaConfig") || line.includes("import { SepoliaConfig"),
    fix: "use ZamaEthereumConfig — single config covers Sepolia and mainnet via block.chainid (see references/anti-patterns.md §1.3)",
  },
];

// The Promise.all-near-Decrypt pattern needs whole-file context, not line-by-line.
const PROMISE_ALL_PATTERN = {
  name: "Promise.all racing fhevm decrypt calls (mock cursor)",
  fix: "serialize decrypt calls with sequential await — see references/core-rules.md CR-3 and references/testing.md §5.1",
};

const SCAN_DIRS = ["contracts", "test"];
const SCAN_EXTS = /\.(sol|ts|tsx|js)$/;

function findFiles(dir) {
  if (!fs.existsSync(dir)) return [];
  const out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      out.push(...findFiles(full));
    } else if (SCAN_EXTS.test(entry.name)) {
      out.push(full);
    }
  }
  return out;
}

function scanFile(filePath) {
  const content = fs.readFileSync(filePath, "utf8");
  const lines = content.split("\n");
  const matches = [];

  // Per-line patterns
  for (let i = 0; i < lines.length; i++) {
    for (const p of PATTERNS) {
      if (p.test(lines[i])) {
        matches.push({ pattern: p.name, line: i + 1, fix: p.fix });
      }
    }
  }

  // Promise.all-near-Decrypt: scan for `Promise.all` and a decrypt helper
  // within ~10 lines on either side (covers multi-line array literals).
  const promiseAllRe = /Promise\.all\s*\(/g;
  const decryptRe = /\b(publicDecryptEuint|userDecryptEuint|publicDecryptEbool|userDecryptEbool|publicDecryptEaddress|userDecryptEaddress)\b/;
  let m;
  while ((m = promiseAllRe.exec(content)) !== null) {
    const promiseAllLine = content.substring(0, m.index).split("\n").length;
    const startLine = Math.max(0, promiseAllLine - 10);
    const endLine = Math.min(lines.length, promiseAllLine + 10);
    const window = lines.slice(startLine, endLine).join("\n");
    if (decryptRe.test(window)) {
      matches.push({
        pattern: PROMISE_ALL_PATTERN.name,
        line: promiseAllLine,
        fix: PROMISE_ALL_PATTERN.fix,
      });
    }
  }

  return matches;
}

function main() {
  let total = 0;
  for (const dir of SCAN_DIRS) {
    for (const file of findFiles(dir)) {
      const matches = scanFile(file);
      for (const m of matches) {
        console.log(`${file}:${m.line}  ${m.pattern}`);
        console.log(`  fix: ${m.fix}`);
        total += 1;
      }
    }
  }

  if (total === 0) {
    console.log("OK: no refused patterns found.");
    process.exit(0);
  } else {
    console.log(`\nFAILED: ${total} refused-pattern match(es) found.`);
    process.exit(1);
  }
}

main();
