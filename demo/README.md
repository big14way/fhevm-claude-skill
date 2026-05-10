# Demo — SealedBidAuction

A confidential first-price sealed-bid auction. Three pre-registered bidders submit encrypted bids before a deadline. After the deadline, the admin reveals only the winning amount via public decryption — losing bids stay encrypted forever, and no participant ever learns another's bid.

**Built using [this skill](../skill/).** Demonstrates several of the load-bearing patterns the skill teaches:

- **Per-bidder ACL with aggregate revealed via public decryption** — each bidder can decrypt their own bid; the winning amount is publicly readable after `reveal()`; losing bids never become readable. See `skill/references/access-control.md` §4 for the canonical multi-user pattern.
- **Encrypted comparison without leaking ordering** — `reveal()` builds the running max via `FHE.gt(...) → ebool → FHE.select(...)` to avoid branching on encrypted values. See `skill/references/operations.md` §2.4.
- **Deadline-gated public decryption** — `FHE.makePubliclyDecryptable` is only called inside `reveal()`, which itself requires `block.timestamp >= deadline`. See `skill/references/decryption.md` §2.
- **Per-handle ACL re-grants on every state mutation** — every `FHE.add` / `FHE.select` / `fromExternal` is followed by `FHE.allowThis`, plus `FHE.allow` for the bidder. See `skill/references/core-rules.md` CR-1.
- **Sequential awaits in tests** — every `fhevm.userDecryptEuint` / `fhevm.publicDecryptEuint` call is sequential, not `Promise.all`. See CR-3.

## Files

```
demo/
├── README.md               # this file
├── contracts/
│   └── SealedBidAuction.sol
└── test/
    └── SealedBidAuction.ts
```

## Running locally

The demo is structured to drop into any Hardhat project built on the [Zama FHEVM Hardhat template](https://github.com/zama-ai/fhevm-hardhat-template):

```bash
# from a Hardhat project root with @fhevm/hardhat-plugin and @fhevm/solidity installed
cp /path/to/demo/contracts/SealedBidAuction.sol contracts/
cp /path/to/demo/test/SealedBidAuction.ts test/
npx hardhat compile
npx hardhat test test/SealedBidAuction.ts
```

Expected: 7 tests passing, all in mock mode (~500ms total). The tests cover deploy, bid validation, deadline enforcement, the admin-reveal flow, the happy path with three bidders, and the per-bidder ACL property (a non-bidder cannot decrypt another bidder's bid).

## Privacy property in plain language

> Three bidders submit sealed bids. After the deadline, the admin announces the winning amount. Nobody — not the admin, not the other bidders, not anyone reading the chain — ever learns the losing bidders' amounts.

This is exactly the property a real-world sealed-bid auction promises. The encryption keeps it true on a public blockchain.

## What the skill produced

This contract and test pair were built using the patterns the skill teaches. The full skill — anti-patterns, core rules, operation composition, ACL discipline, decryption flows — lives one directory up at `skill/`. The skill's reference files are cross-referenced from comments inside this contract, so a reader can trace any pattern back to its substantive treatment.

## Tags

- `[mock-verified 2026-05-10]` — all 7 tests pass against `@fhevm/hardhat-plugin@0.4.2` and `@fhevm/solidity@0.11.1`.
- Live-network deployment (Sepolia) is the next step; the contract is structured to deploy without changes.
