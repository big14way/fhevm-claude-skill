// Test template — minimal correct shape for an FHEVM contract test.
// Targets @fhevm/hardhat-plugin ≥0.4.2.
// Pairs with templates/Contract.sol — both files use MyContract; rename in
// lockstep when adapting.
//
// CR-3 reminder: when this template grows multiple decryption calls, they
// must be sequential awaits, not Promise.all. The mock coprocessor's event
// cursor is not concurrency-safe. See references/testing.md §5.1.

import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import { ethers, fhevm } from "hardhat";
import { MyContract, MyContract__factory } from "../types";
import { expect } from "chai";
import { FhevmType } from "@fhevm/hardhat-plugin";

describe("MyContract", function () {
    let contract: MyContract;
    let alice: HardhatEthersSigner;
    let contractAddress: string;

    beforeEach(async function () {
        // Skip in live mode — see references/testing.md §2.1 for the gate-skip pattern.
        if (!fhevm.isMock) {
            this.skip();
            return;
        }

        const ethSigners: HardhatEthersSigner[] = await ethers.getSigners();
        alice = ethSigners[0];

        const factory = (await ethers.getContractFactory("MyContract")) as MyContract__factory;
        contract = (await factory.deploy()) as MyContract;
        contractAddress = await contract.getAddress();
    });

    it("exampleMutate accepts an encrypted input and updates state", async function () {
        // TODO: Replace this with assertions for your contract's actual logic.
        //   - Arrange: create the encrypted input bound to (contract, signer)
        //     — see references/input-proofs.md §1.1 for the binding rule
        //   - Act: call the mutating function with handle + proof
        //   - Assert: read the resulting state via the getter and decrypt off-chain
        //     — see references/testing.md §4 for the return-type discipline

        // Arrange — encrypted input bound to this contract and this signer
        const enc = await fhevm
            .createEncryptedInput(contractAddress, alice.address)
            .add32(5n)
            .encrypt();

        // Act
        await (
            await contract.connect(alice).exampleMutate(enc.handles[0], enc.inputProof)
        ).wait();

        // Assert — read the encrypted handle, decrypt off-chain, verify the value.
        // Note the bigint literal `5n` — fhevm.userDecryptEuint returns bigint.
        // See references/testing.md §4.2 for the bigint trap.
        const handle = await contract.getState();
        const value = await fhevm.userDecryptEuint(
            FhevmType.euint32,
            handle,
            contractAddress,
            alice
        );
        expect(value).to.eq(5n);
    });
});
