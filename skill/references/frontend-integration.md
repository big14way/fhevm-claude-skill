# Frontend integration — the relayer SDK

Version stamp: this file targets `@zama-fhe/relayer-sdk ≥0.4`.

This file covers the boundary where contracts meet code that runs in browsers, Node.js scripts, or other JavaScript environments. The relayer SDK is how non-Solidity code creates encrypted inputs, decrypts handles, and connects to the FHEVM coprocessor's HTTP relayer.

```
§1  When to use the relayer SDK
§2  Creating an instance
§3  Wallet integration patterns
§4  React integration
§5  Stale SDK patterns to refuse
§6  What this file does not cover
```

This file focuses on what's distinctive about FHEVM frontend integration. General topics — wallet UX, EIP-712 mechanics, React state management — are user-side education and are deferred to the demo repo and external resources.

---

## §1 — When to use the relayer SDK

The relayer SDK is the frontend boundary. Three contexts use it:

- **Browser frontends** that let users encrypt inputs, sign EIP-712 typed data, and decrypt their own handles. The dominant case.
- **Node.js scripts** that interact with deployed FHEVM contracts directly — admin tools, indexers, batch jobs, automated decryption pipelines. The SDK has a node entry point with a slightly different init shape.
- **Tests that exercise the live relayer** (rare; most tests use `@fhevm/hardhat-plugin`'s mock instead — see `references/testing.md`).

The SDK is **not** for:

- On-chain Solidity code. Use `@fhevm/solidity` and the FHE library.
- Hardhat tests that should run in mock mode. Use `@fhevm/hardhat-plugin`'s `fhevm.publicDecryptEuint`, `fhevm.userDecryptEuint`, and `fhevm.createEncryptedInput`.
- Wallet implementation. The SDK consumes wallet objects (`Eip1193Provider`); it does not provide them.

If an agent is writing Solidity, it does not import from `@zama-fhe/relayer-sdk`. If an agent is writing a Hardhat test, it uses the plugin's `fhevm` helper, not the relayer SDK directly. The SDK's surface is for code that talks to a live deployed coprocessor.

---

## §2 — Creating an instance

An SDK instance is the object every frontend operation runs on. It holds the network configuration, knows the relayer's HTTP endpoints, and exposes the `createEncryptedInput`, `userDecrypt`, `publicDecrypt`, and related methods.

### §2.1 — The config: what's required, what's preset  [grep-verified]

`createInstance(config)` accepts an `FhevmInstanceConfig` object with several required fields including five coprocessor contract addresses, `gatewayChainId`, `relayerUrl`, and `network`. Assembling them manually is error-prone; the SDK ships preset configs for the canonical networks:

```typescript
import { createInstance, SepoliaConfig, MainnetConfig } from "@zama-fhe/relayer-sdk/web";

// Sepolia testnet — the common case during development
const instance = await createInstance({
    ...SepoliaConfig,
    network: window.ethereum,   // or an RPC URL string; see §2.2
});

// Mainnet — production
const instance = await createInstance({
    ...MainnetConfig,
    network: window.ethereum,
});
```

Both presets are exposed in both the node and web entry points. They omit `network`, which the caller supplies based on environment.

**Both `SepoliaConfig` and `MainnetConfig` have versioned variants** (`SepoliaConfigV1`, `SepoliaConfigV2`, etc.). The unversioned form points at the current stable protocol version; the versioned forms pin to specific releases. For new code, use the unversioned form. See §5.1 for the anti-pattern of reaching for a versioned variant by default.

### §2.2 — The network field: `Eip1193Provider | string`  [grep-verified]

The `network` field accepts two shapes, and choosing correctly is the most consequential frontend-side decision:

```typescript
network: Eip1193Provider | string
```

**`Eip1193Provider`** — a wallet object exposing the EIP-1193 interface (`request({ method, params })`). This is what a browser frontend almost always uses. `window.ethereum` (MetaMask, Rabby, others), a WalletConnect adapter, or a programmatic wallet that implements the interface. User actions (signing, sending transactions) trigger wallet prompts.

```typescript
// Browser frontend
const instance = await createInstance({
    ...SepoliaConfig,
    network: window.ethereum,
});
```

**`string`** — an RPC URL. This is for code that doesn't have a wallet and doesn't need user prompts. Node.js scripts, admin tools, batch decryption jobs, indexers. The script signs with whatever private key it has, typically via ethers.js or viem; the relayer SDK only needs the URL to know what chain it's talking to.

```typescript
// Node script
import { createInstance, SepoliaConfig } from "@zama-fhe/relayer-sdk/node";

const instance = await createInstance({
    ...SepoliaConfig,
    network: process.env.SEPOLIA_RPC_URL,
});
```

**Choose the form based on whether user interaction is in the picture.** A frontend that asks users to sign typed data passes the `Eip1193Provider`. A backend script that runs unattended passes the RPC URL. Mixing them — passing an RPC URL in a frontend that needs `signTypedData_v4`, or a wallet object in an unattended script — produces failures that look like SDK bugs but are actually environment mismatches.

### §2.3 — `initSDK` and the web-only init step  [grep-verified]

Web environments require an additional initialization step before `createInstance`:

```typescript
import { initSDK, createInstance, SepoliaConfig } from "@zama-fhe/relayer-sdk/web";

const ok = await initSDK();   // loads WASM; returns Promise<boolean>
if (!ok) {
    // initSDK reports failure via false return, not a thrown error
    throw new Error("Failed to initialize relayer SDK");
}

const instance = await createInstance({
    ...SepoliaConfig,
    network: window.ethereum,
});
```

`initSDK` returns `Promise<boolean>` — it can fail and return false, distinct from throwing. Agents should check the return value, not assume success.

`initSDK` accepts three optional parameters: `tfheParams`, `kmsParams`, and `thread`. Calling `initSDK()` with no arguments is valid and uses defaults. The parameters control WASM loading detail (which TFHE parameter set, which KMS configuration, threading enabled) and are typically only adjusted for non-default deployments. [reasoned — the parameter shape is grep-verified; the "typically only adjusted" framing is the author's read, not extracted]

Node entries do not expose `initSDK`. Calling it from a node script will fail at the import. `createInstance` is the only init step needed in node:

```typescript
// Node — no initSDK
import { createInstance, SepoliaConfig } from "@zama-fhe/relayer-sdk/node";
const instance = await createInstance({ ...SepoliaConfig, network: rpcUrl });
```

**The asymmetry is the most common frontend integration footgun.** A developer copying node example code into a browser context, or vice versa, will hit:

- Web frontend without `initSDK`: SDK calls fail with "WASM not loaded" or similar. The error doesn't say "you need initSDK" explicitly.
- Node script calling `initSDK`: Import fails because the node entry doesn't export it.

Fix: import from the right entry (`@zama-fhe/relayer-sdk/web` or `@zama-fhe/relayer-sdk/node`), and call `initSDK` if and only if the import is from `web`.

### §2.4 — Other instance methods  [grep-verified]

Beyond the decryption methods (`publicDecrypt`, `userDecrypt`, `delegatedUserDecrypt`) covered in `references/decryption.md`, an instance exposes:

- **`createEncryptedInput(contractAddress, userAddress)`** — frontend equivalent of the test plugin's input creation. Builds an encrypted input bound to a specific contract and sender. See `references/input-proofs.md` §1.2.
- **`generateKeypair()`** — produces an ephemeral keypair for the user-decryption envelope. See `references/decryption.md` §3.2.
- **`config: FhevmConfigType`** — the resolved config. Read-only access for code that needs to inspect what the instance is talking to.
- **`requestZKProofVerification(zkProof, options?)`** — exists; this skill does not cover its use. ZK-proof verification is a specialized flow, likely related to batch input proofs, that has not been part of the skill's scope. If an agent encounters this in a contract or example, treat it as out-of-scope and consult Zama docs.

The instance also exposes URL accessors (`publicDecryptUrl`, `userDecryptUrl`, `delegatedUserDecryptUrl`) — useful for debugging connectivity but rarely called directly in application code.

---

## §3 — Wallet integration patterns

The relayer SDK consumes wallets; it does not provide them. Wallet integration is mostly outside the SDK's surface, but two FHEVM-specific aspects matter.

### §3.1 — `signTypedData_v4`: the EIP-712 boundary  [reasoned, with references]

User decryption (`references/decryption.md` §3) and delegated decryption (§4 of the same file) require the user to sign EIP-712 typed data. The flow is:

```typescript
// 1. SDK builds the typed data
const eip712 = instance.createEIP712(publicKey, [contractAddress], startTimestamp, durationDays);

// 2. Wallet signs it — this is the wallet's responsibility, not the SDK's
const signature = await wallet.signTypedData(eip712.domain, eip712.types, eip712.message);

// 3. SDK posts the signed request to the relayer
const result = await instance.userDecrypt(handles, privateKey, publicKey, signature, ...);
```

Step 2 is where wallet integration happens. The SDK does not call `signTypedData_v4` itself; it gives the frontend the typed-data structure and expects the frontend to obtain the signature.

In ethers.js: `signer.signTypedData(domain, types, message)`. In viem: `walletClient.signTypedData({ domain, types, primaryType, message })`. In raw EIP-1193: `provider.request({ method: 'eth_signTypedData_v4', params: [address, JSON.stringify(typedData)] })`. The SDK doesn't care which library the frontend uses, only that the resulting signature is a valid EIP-712 signature over the structure it produced.

**FHEVM-specific framing:** the validity window (`startTimestamp`, `durationDays`) passed to `createEIP712` must match the values passed to `userDecrypt`. The relayer's signature verification rejects mismatches. See `references/decryption.md` §3.5 for the diagnostic.

### §3.2 — Common wallet-side errors that look like SDK errors

Three failure modes that show up at the SDK call but originate at the wallet:

- **User rejects the signature prompt.** The wallet throws (typically a `4001` error code in EIP-1193). The SDK call never gets a signature, so subsequent `userDecrypt` doesn't run. Surface this in UX as a "user cancelled" state, not a "decryption failed" error.
- **Wallet not connected to the expected chain.** The wallet's signature is valid but the chain ID in the EIP-712 domain doesn't match. The relayer rejects. Check `wallet.getNetwork().chainId` matches the instance's `gatewayChainId` before signing.
- **Account switch mid-flow.** User starts the decryption flow with one account, switches accounts before signing. The signature is from a different address than the one with ACL on the handle. The relayer rejects with the user-decrypt ACL error. Pin the signing account at flow start and verify it matches the handle's ACL grant.

These errors are wallet-environment problems, not SDK problems. Diagnose at the wallet boundary first.

---

## §4 — React integration  [reasoned]

The relayer SDK is framework-agnostic — there are no React-specific exports. Three FHEVM-relevant concerns shape any React integration:

- `initSDK` and `createInstance` are async and can take seconds (WASM load is MB-scale). Render a loading state until the instance is ready; do not block UI on init.
- The instance is shared mutable state. Pass it via context, not as a prop. Components that consume the instance should be rendered only after init resolves.
- Two distinct failure modes need handling: `initSDK` returns `Promise<boolean>` (reports failure via false), `createInstance` throws on bad config. UI should distinguish "WASM failed to load" from "config rejected" because the user-facing remediation differs.

Working React components — including the gating, context, and error patterns — live in the demo repo. This file does not attempt to be a React tutorial.

---

## §5 — Stale SDK patterns to refuse

### §5.1 — Reaching for a versioned config preset by default  [grep-verified for the existence of variants; reasoned for the recommendation]

**Pattern to refuse:**

```typescript
import { SepoliaConfigV1 } from "@zama-fhe/relayer-sdk/web";   // pinned to v1
const instance = await createInstance({ ...SepoliaConfigV1, network: window.ethereum });
```

**Why the agent will generate this:** If an LLM has training data referencing specific versioned config names (`SepoliaConfigV1`, `MainnetConfigV2`, etc.), it may reach for them as if they were the canonical name. Versioned variants are real symbols and will compile, so the agent gets no immediate signal.

**Correct replacement:**

```typescript
import { SepoliaConfig } from "@zama-fhe/relayer-sdk/web";    // current stable
const instance = await createInstance({ ...SepoliaConfig, network: window.ethereum });
```

The unversioned form (`SepoliaConfig`, `MainnetConfig`) points at the current stable protocol version. Versioned forms pin to specific releases and are correct only when the contract being interacted with was deployed against that specific protocol version. For new code, use the unversioned form unless there's a deliberate reason not to.

This parallels `references/anti-patterns.md` §1.3 on the Solidity-side `SepoliaConfig` — same flavor of "version-pinned name leads to stale code as protocol versions advance."

### §5.2 — Calling `initSDK` from node, or skipping it in web  [grep-verified]

**Pattern to refuse (web):**

```typescript
import { createInstance, SepoliaConfig } from "@zama-fhe/relayer-sdk/web";
// MISSING: await initSDK();
const instance = await createInstance({ ...SepoliaConfig, network: window.ethereum });
// Subsequent calls fail with "WASM not loaded" or similar
```

**Pattern to refuse (node):**

```typescript
import { initSDK, createInstance, SepoliaConfig } from "@zama-fhe/relayer-sdk/node";
// FAILS AT IMPORT — initSDK is not exported from the node entry
```

**Why the agent will generate this:** Two distinct LLM failure modes. Either (a) the agent has training data showing `createInstance` without `initSDK` and copies that into a web context, or (b) the agent generates web init code in a node script because the two environments aren't visibly distinguished in user-facing prompts.

**Correct fix:** Import from the right entry, and call `initSDK` if and only if the entry is `web`. See §2.3.

---

## §6 — What this file does not cover

- **Implementations of `Eip1193Provider`**: building a wallet, MetaMask integration patterns, WalletConnect setup, account-switching UX. Wallet engineering is its own domain and outside an FHEVM skill's scope.
- **Full EIP-712 typed-data construction without the SDK**: the `UserDecryptRequestVerification` and delegated equivalents have specific schemas; consult Zama docs for manual construction. See `references/decryption.md` §3.3.
- **`requestZKProofVerification`**: exists on the instance; this skill has no log backing on its use. If an agent encounters it, treat as out-of-scope and consult docs.
- **Production deployment patterns**: bundling, code-splitting, WASM hosting, CSP configuration for `initSDK`'s WASM load. Standard frontend deployment concerns; not FHEVM-specific.
- **Working React/Next.js examples**: §4 documents the patterns; the demo repo will include working components.

---

## Cross-references

- Encrypted input creation in tests vs frontend → `references/input-proofs.md` §1
- The full user-decryption flow → `references/decryption.md` §3
- Delegated decryption → `references/decryption.md` §4
- Mock-mode testing instead of live relayer → `references/testing.md` (when drafted)
- Diagnosing the errors named in §3.2 and §5 → `references/troubleshooting.md` (when drafted)
