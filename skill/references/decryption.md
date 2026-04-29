# Decryption — public, user, and delegated flows

Version stamp: this file targets `@fhevm/solidity ≥0.10`, `@zama-fhe/relayer-sdk ≥0.4`.

This file covers how encrypted handles become plaintext. There are three flows, each with distinct on-chain and off-chain surfaces:

```
§1  Overview — the three decryption flows and when to use which
§2  Public decryption — handle marked publicly decryptable, anyone reads off-chain
§3  User decryption — handle ACL'd to a specific address, that address reads via EIP-712
§4  Delegated user decryption — delegator authorizes a delegate to read on their behalf
§5  When decryption fails — diagnostic surface
§6  What this file does not cover
```

This file leans on the relayer SDK (`@zama-fhe/relayer-sdk`) for off-chain mechanics. The SDK is a frontend dependency; for instance configuration, init asymmetry between node and web, and React patterns, see `references/frontend-integration.md`.

---

## §1 — Overview

Three decryption flows exist, gated by who needs to read the plaintext and how the on-chain handle was prepared:

| Flow | On-chain mark | Off-chain caller | EIP-712 needed | Use case |
|---|---|---|---|---|
| Public | `FHE.makePubliclyDecryptable(handle)` | anyone | no | reveal final results, public auctions, transparency |
| User | `FHE.allow(handle, userAddress)` | the granted user | yes (signed by user) | private balances, individual contributions, owner-only state |
| Delegated | `FHE.allow(handle, delegatorAddress)` + on-chain delegation grant | the delegate (acting for delegator) | yes (signed by delegate) | account abstraction, custody services, helper services that decrypt on a user's behalf |

**Decision rule for designing a contract.** The flow is determined by the on-chain ACL, not by the off-chain code. A handle marked `makePubliclyDecryptable` is publicly readable — there is no SDK call that "uses an EIP-712 signature on a public handle"; the relayer endpoint is different. Conversely, a handle ACL'd to a specific user cannot be read via the public endpoint — the relayer rejects the request.

Choose the on-chain mark first; the off-chain flow follows.

---

## §2 — Public decryption  [grep-verified]

### 2.1 Marking a handle publicly decryptable

```solidity
// Inside the contract
function reveal() external onlyAdmin {
    FHE.makePubliclyDecryptable(_finalTally);
    // _finalTally is now publicly decryptable — anyone with the handle can read off-chain
    emit Revealed(...);
}
```

Once marked, the handle remains publicly decryptable for its lifetime. There is no "unmark" operation — same append-only constraint as ACL grants (see `references/access-control.md` §3.1). The only way to "hide" a previously-revealed handle is to produce a fresh handle (via any FHE op) and not mark the new one.

### 2.2 Reading the plaintext off-chain

```typescript
import { createInstance } from "@zama-fhe/relayer-sdk";

const instance = await createInstance({ /* network config */ });
const result = await instance.publicDecrypt([handle1, handle2]);
// result is { handle1: plaintext1, handle2: plaintext2 }
```

`publicDecrypt(handles, options?)` takes an array of handles (as `string` or `Uint8Array`) and returns a `Promise<PublicDecryptResults>`. No keypair, no signature, no EIP-712 — public decryption is structurally simpler than the user flow. The instance hits `instance.publicDecryptUrl` (a relayer endpoint), which fetches and returns the plaintexts.

### 2.3 The uninitialized-handle behavior  [grep-verified]

`FHE.makePubliclyDecryptable` does **not** revert when called on an uninitialized handle. The function source for every type begins with an `isInitialized` check that silently substitutes a type-appropriate default:

```solidity
function makePubliclyDecryptable(euint32 value) internal returns (euint32) {
    if (!isInitialized(value)) {
        value = asEuint32(0);
    }
    Impl.makePubliclyDecryptable(euint32.unwrap(value));
    // ...
}
```

Default substitutions per type: `ebool` → `false`, `euint8`–`euint256` → `0`, `eaddress` → `address(0)`.

**Footgun:** an agent calling `makePubliclyDecryptable` on a state variable that's never been written to publishes the substituted zero, not an error and not a "no value yet" signal. The off-chain caller decrypts to zero successfully and may interpret that as a real result. If the contract has a "tally was zero" / "tally was never set" distinction to preserve, track it in a separate boolean state variable — the encrypted handle alone cannot carry the distinction.

This applies to every overload of `makePubliclyDecryptable`. There is no per-type variant that reverts on uninitialized state.

---

## §3 — User decryption  [grep-verified for SDK API; reasoned for the envelope-encryption mechanism]

User decryption lets a specific address — granted ACL via `FHE.allow(handle, userAddress)` on-chain — read the plaintext off-chain. The flow is four steps. The relayer SDK exposes a function for each.

### 3.1 The four-step flow

```typescript
// Step 1: ephemeral keypair (frontend)
const { publicKey, privateKey } = instance.generateKeypair();

// Step 2: build EIP-712 typed data (frontend)
const eip712 = instance.createEIP712(
    publicKey,
    [contractAddress],
    startTimestamp,
    durationDays
);

// Step 3: user signs the typed data (wallet)
const signature = await wallet.signTypedData(
    eip712.domain,
    eip712.types,
    eip712.message
);

// Step 4: post to relayer (frontend)
const result = await instance.userDecrypt(
    [{ handle, contractAddress }],
    privateKey,
    publicKey,
    signature,
    [contractAddress],
    userAddress,
    startTimestamp,
    durationDays
);
// result is a UserDecryptResults map keyed by handle
```

### 3.2 Step 1: `generateKeypair()`  [grep-verified]

```typescript
instance.generateKeypair(): KeypairType<BytesHexNo0x>;
```

Generates an ephemeral keypair. The privateKey is held by the frontend for the duration of this decryption request and not stored — it exists only to receive the relayer's response (see §3.6 below).

### 3.3 Step 2: `createEIP712(publicKey, contractAddresses, startTimestamp, durationDays)`  [grep-verified]

```typescript
instance.createEIP712(
    publicKey: string,
    contractAddresses: string[],
    startTimestamp: number,
    durationDays: number
): KmsUserDecryptEIP712Type;
```

Builds the typed-data structure for the user to sign. The `contractAddresses` array names every contract whose handles the user wants to decrypt in this batch — the signature authorizes decryption of handles from those specific contracts only.

`startTimestamp` and `durationDays` define the **validity window** of the resulting decryption authorization. See §3.5.

The full `UserDecryptRequestVerification` field schema isn't extracted in this skill. If a frontend needs to construct the typed-data manually (without the SDK), consult Zama's docs for the schema. [docs-sourced for schema details]

### 3.4 Step 3: wallet signs the typed data

The user's wallet (MetaMask, WalletConnect, etc.) signs via `eth_signTypedData_v4` or equivalent. This is outside the relayer SDK — the SDK produces the typed-data structure; the wallet handles the signature.

The signature attests "I am the user; I authorize decryption of the handles in `contractAddresses` for the validity window starting at `startTimestamp` for `durationDays`."

### 3.5 The validity window — `startTimestamp + durationDays`  [grep-verified]

The same `startTimestamp` and `durationDays` are passed to **both** `createEIP712` (signing) and `userDecrypt` (relayer call). They must match.

Common failure: signing for one window and calling `userDecrypt` with different values. The relayer rejects the request because the signature it verifies references one window and the request claims another. The diagnostic surface (§5) includes this case.

`durationDays` is the time the authorization remains valid. Within that window, the user can call `userDecrypt` with the same signature multiple times without re-signing. Outside the window, the signature is rejected.

### 3.6 Step 4: `userDecrypt(...)`  [grep-verified for surface; reasoned for envelope-encryption]

```typescript
instance.userDecrypt(
    handles: HandleContractPair[],
    privateKey: string,
    publicKey: string,
    signature: string,
    contractAddresses: string[],
    userAddress: string,
    startTimestamp: number,
    durationDays: number,
    options?: RelayerUserDecryptOptionsType
): Promise<UserDecryptResults>;
```

Posts to `instance.userDecryptUrl` (a relayer endpoint distinct from the public-decrypt endpoint). The relayer:

1. Verifies the EIP-712 signature against `userAddress` and `publicKey`.
2. Verifies on-chain ACL — `userAddress` must have ACL on every requested handle from the contracts in `contractAddresses`.
3. Decrypts the handles and returns plaintexts.

**The role of the privateKey.** [reasoned — envelope-encryption inference] The `privateKey` parameter exists for response confidentiality. The EIP-712 signature authenticates *who is asking*; the keypair encrypts *the response in transit*. The relayer encrypts the plaintext response with `publicKey`; the frontend decrypts with `privateKey`. Without the keypair, the plaintext would travel from the relayer to the frontend in the clear, defeating the confidentiality property the on-chain encryption provided. This inference is consistent with the keypair's lifetime (ephemeral, frontend-only) and the function's parameter list, but the cryptographic detail is not visible from the SDK's `.d.ts` and is outside this skill's verified scope. [docs-sourced for the response cryptography]

### 3.7 Init asymmetry — node vs web  [grep-verified]

`createInstance(config)` is exposed in both `node.d.ts` and `web.d.ts`. But web environments require an additional initialization step:

```typescript
// Web only
import { initSDK, createInstance } from "@zama-fhe/relayer-sdk/web";
await initSDK({ tfheParams?, kmsParams?, thread? });   // loads WASM
const instance = await createInstance(config);
```

`initSDK` only exists in the web entry. Node and bundle entries skip it. A frontend developer copying node code into a web context will hit "WASM not loaded" errors on the first SDK call.

See `references/frontend-integration.md` for the full init treatment, including which params `initSDK` accepts and how to surface init errors to users.

---

## §4 — Delegated user decryption  [grep-verified for SDK API and on-chain surface]

Delegation lets one address (the **delegator**) authorize another (the **delegate**) to decrypt handles on the delegator's behalf. The on-chain side establishes the delegation; the off-chain side uses a parallel SDK surface that takes both addresses explicitly.

### 4.1 The on-chain side — establishing delegation  [grep-verified]

`FHE.sol` exposes six delegation functions:

```solidity
delegateUserDecryption(...)                      // with expiration
delegateUserDecryptionWithoutExpiration(...)     // permanent until revoked
revokeUserDecryptionDelegation(...)              // single revoke
revokeUserDecryptionDelegations(...)             // batch revoke
isDelegatedForUserDecryption(...)                // view
getDelegatedUserDecryptionExpirationDate(...)    // view
```

The delegation context is a `(delegate, contractAddress)` pair — a delegate is authorized to decrypt-on-behalf-of-delegator for handles from a specific contract. To delegate across multiple contracts, the delegator calls `delegateUserDecryption` once per contract.

**Delegation is revocable** (unlike per-handle ACL grants — see `references/access-control.md` §3.1). The delegator can revoke at any time via `revokeUserDecryptionDelegation(delegate, contractAddress)`. The two flavors `delegateUserDecryption` (expiring) and `delegateUserDecryptionWithoutExpiration` differ in whether revocation requires an explicit call or happens automatically at expiration.

### 4.2 The off-chain side — the parallel SDK surface  [grep-verified]

The relayer SDK exposes a **dedicated delegated-decryption flow**, parallel to (not a special case of) standard user decryption. Three relevant additions over §3:

```typescript
instance.createDelegatedUserDecryptEIP712(
    publicKey: string,
    contractAddresses: string[],
    delegatorAddress: string,        // explicit
    startTimestamp: number,
    durationDays: number
): KmsDelegatedUserDecryptEIP712Type;

instance.delegatedUserDecrypt(
    handleContractPairs: HandleContractPair[],
    privateKey: string,
    publicKey: string,
    signature: string,
    contractAddresses: string[],
    delegatorAddress: string,        // who delegated
    delegateAddress: string,         // who's acting on their behalf
    startTimestamp: number,
    durationDays: number,
    options?: RelayerUserDecryptOptionsType
): Promise<UserDecryptResults>;

// And a third HTTP endpoint
get delegatedUserDecryptUrl(): string;
```

The structural differences from §3:

- Both `delegatorAddress` and `delegateAddress` are explicit parameters.
- The EIP-712 typed-data structure is **distinct** — `KmsDelegatedUserDecryptEIP712Type` vs `KmsUserDecryptEIP712Type`. The delegated typed-data includes `delegatorAddress` as a typed field, so the relayer's signature verification walks a different schema for delegated requests.
- The relayer has a third endpoint (`delegatedUserDecryptUrl`) — not the same as `userDecryptUrl`.

### 4.3 The flow

```typescript
// Steps 1-3 mirror §3 with the delegated EIP-712 builder
const { publicKey, privateKey } = instance.generateKeypair();

const eip712 = instance.createDelegatedUserDecryptEIP712(
    publicKey,
    [contractAddress],
    delegatorAddress,
    startTimestamp,
    durationDays
);

const signature = await delegateWallet.signTypedData(/* ... */);  // delegate signs

// Step 4: posts to the delegated endpoint
const result = await instance.delegatedUserDecrypt(
    handleContractPairs,
    privateKey,
    publicKey,
    signature,
    [contractAddress],
    delegatorAddress,
    delegateAddress,
    startTimestamp,
    durationDays
);
```

The delegate signs (with the delegate's wallet, against the delegate's address). The delegator does not sign anything off-chain — their authorization was established earlier via the on-chain `delegateUserDecryption` call. The relayer:

1. Verifies the EIP-712 signature against `delegateAddress`.
2. Verifies on-chain that `delegatorAddress` has ACL on the requested handles.
3. Verifies on-chain that `delegateAddress` is currently delegated for `(delegatorAddress, contractAddress)` and that the delegation has not expired.
4. Decrypts and returns plaintexts.

[reasoned for the relayer-side verification ordering — the function surface implies these checks but the order isn't grep-extractable from `.d.ts`]

### 4.4 When to use delegation

Three canonical use cases:

- **Custody services.** A custodial wallet that holds assets on behalf of users decrypts balances on the user's behalf without requiring the user to sign each request.
- **Account abstraction with helper services.** An AA wallet delegates to a relayer-helper that performs decryption-and-action workflows without the user being online.
- **Read-only delegate roles.** A reporting service or auditor delegated to read specific contracts' encrypted state for a fixed duration.

Delegation is the answer when "I want X to read this on my behalf" is the requirement. If the user is willing to sign each request directly, standard user decryption (§3) is structurally simpler — no on-chain delegation step is needed.

---

## §5 — When decryption fails — diagnostic surface

Common failure modes across the three flows, with their distinguishing symptoms:

| Symptom | Likely flow | Likely cause | Fix |
|---|---|---|---|
| `publicDecrypt` returns successfully but plaintext is `0`/`false`/`address(0)` | Public | Handle was uninitialized when `makePubliclyDecryptable` was called; default substituted | Track "value was set" separately; never rely on the decrypted zero to mean "no value" |
| `publicDecrypt` request rejected by relayer | Public | Handle was not marked publicly decryptable on-chain | Call `FHE.makePubliclyDecryptable(handle)` first |
| `userDecrypt` rejected with signature error | User | EIP-712 signature mismatch — wrong signer, wrong typed-data, wrong window | Verify signer wallet, re-call `createEIP712` with the same window passed to `userDecrypt` |
| `userDecrypt` rejected with ACL error | User | `userAddress` lacks ACL on the handle | Call `FHE.allow(handle, userAddress)` on-chain before decryption |
| `userDecrypt` validity-window mismatch | User | `startTimestamp`/`durationDays` differ between `createEIP712` and `userDecrypt` | Pass the same values to both calls |
| `delegatedUserDecrypt` rejected with delegation-not-found | Delegated | On-chain delegation was not established or has expired | Call `delegateUserDecryption(delegate, contract)` from the delegator's address; check expiration via `getDelegatedUserDecryptionExpirationDate` |
| `delegatedUserDecrypt` rejected with ACL error | Delegated | `delegatorAddress` lacks ACL on the handle (delegate inherits from delegator's ACL) | Call `FHE.allow(handle, delegatorAddress)` on-chain — delegation does not bypass ACL |
| Web frontend fails on first SDK call with "WASM not loaded" | All | `initSDK()` not called before `createInstance()` in web environment | Call `initSDK()` first in web; not needed in node |

[mostly reasoned — the diagnostic table maps symptoms to causes based on the function surfaces grep-verified above and the on-chain ACL rules; specific relayer error messages and error codes are not extracted in this file]

---

## §6 — What this file does not cover

- **The cryptographic primitives behind the response envelope.** Reasoned that the `privateKey` parameter encrypts the relayer's response; the actual cipher and key derivation are outside scope.
- **The full `UserDecryptRequestVerification` and `KmsDelegatedUserDecryptEIP712Type` field schemas.** Visible in the SDK's `.cjs` source but not extracted; consult Zama docs for manual typed-data construction.
- **Specific relayer error codes and HTTP response shapes.** The diagnostic table in §5 is reasoned from the function surface; precise error messages for production debugging require docs reference.
- **Init parameters for `initSDK` (TFHE params, KMS params, threads).** See `references/frontend-integration.md`.
- **Wallet integration patterns for `signTypedData_v4`.** See `references/frontend-integration.md`.
- **Live on-chain testing of the user-decrypt and delegated-decrypt flows.** These flows require a live coprocessor connection; this skill verifies API shapes from the installed SDK but does not run end-to-end decryption against the network.

---

## Cross-references

- ACL grants that gate user decryption — `references/access-control.md` §1
- Public-decrypt marking in the context of operations — `references/operations.md` and `references/access-control.md` §3.1
- Delegation surface (existence noted) — `references/access-control.md` §3.3 (forward-references this file's §4 for the substantive treatment)
- Relayer SDK init, network config, React patterns — `references/frontend-integration.md` (when drafted)
- Diagnosing the errors named in §5 — `references/troubleshooting.md` (when drafted)
