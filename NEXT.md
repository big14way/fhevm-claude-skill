# Next session — where to pick up

**File to draft:** `skill/references/operations.md`

**Process:** middle-path per `PROCESS_NOTES.md` (2026-04-18 entry). `operations.md` is op/API-heavy — grep everything before drafting; tag claims `grep-verified` / `compile-verified` / `reasoned` in the draft so coach's review can focus on reasoned claims.

**Opening move:** paste the output of these greps as the first message to the coach (evidence base for the draft):

```bash
cd ~/zama-bounty/learning
grep -n "function add\|function sub\|function mul" node_modules/@fhevm/solidity/lib/FHE.sol | head -40
grep -n "function select" node_modules/@fhevm/solidity/lib/FHE.sol
grep -n "function eq\|function ne\|function lt\|function le\|function gt\|function ge" node_modules/@fhevm/solidity/lib/FHE.sol | head -40
grep -n "function and\|function or\|function xor\|function not" node_modules/@fhevm/solidity/lib/FHE.sol | head -40
grep -n "function shl\|function shr" node_modules/@fhevm/solidity/lib/FHE.sol
grep -n "function min\|function max" node_modules/@fhevm/solidity/lib/FHE.sol
grep -n "function neg" node_modules/@fhevm/solidity/lib/FHE.sol
grep -n "function rand" node_modules/@fhevm/solidity/lib/FHE.sol
```

**Structural note for the draft:** `encrypted-types.md` §2 owns the op-support matrix; `operations.md` owns how to *use* the ops (composition patterns, `FHE.select` idioms, HCU budget concept, branchless conditional patterns). Cross-ref the matrix; don't duplicate it.

**State of play:** 7 of 14 skill files complete. 22 days to May 10 submission. On track.

Delete this file when `operations.md` ships.
