import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import { ethers, fhevm } from "hardhat";
import { SealedBidAuction, SealedBidAuction__factory } from "../types";
import { expect } from "chai";
import { FhevmType } from "@fhevm/hardhat-plugin";

// CR-3 reminder: decrypt calls in this file are sequential awaits, never
// Promise.all. The mock coprocessor's event cursor is not concurrency-safe.

type Signers = {
  admin: HardhatEthersSigner;
  alice: HardhatEthersSigner;
  bob: HardhatEthersSigner;
  carol: HardhatEthersSigner;
};

describe("SealedBidAuction", function () {
  let signers: Signers;
  let contract: SealedBidAuction;
  let contractAddress: string;
  let deadline: number;

  before(async function () {
    const ethSigners: HardhatEthersSigner[] = await ethers.getSigners();
    signers = {
      admin: ethSigners[0],
      alice: ethSigners[1],
      bob: ethSigners[2],
      carol: ethSigners[3],
    };
  });

  beforeEach(async function () {
    if (!fhevm.isMock) {
      console.warn("This test suite requires mock mode.");
      this.skip();
    }

    const now = (await ethers.provider.getBlock("latest"))!.timestamp;
    deadline = now + 3600;

    const factory = (await ethers.getContractFactory("SealedBidAuction")) as SealedBidAuction__factory;
    contract = (await factory.deploy(deadline, [
      signers.alice.address,
      signers.bob.address,
      signers.carol.address,
    ])) as SealedBidAuction;
    contractAddress = await contract.getAddress();
  });

  async function advancePastDeadline() {
    await ethers.provider.send("evm_setNextBlockTimestamp", [deadline + 1]);
    await ethers.provider.send("evm_mine", []);
  }

  async function submit(bidder: HardhatEthersSigner, amount: number) {
    const enc = await fhevm
      .createEncryptedInput(contractAddress, bidder.address)
      .add32(amount)
      .encrypt();
    await (
      await contract.connect(bidder).submitBid(enc.handles[0], enc.inputProof)
    ).wait();
  }

  it("deploys with admin = deployer, deadline stored, revealed = false", async function () {
    expect(await contract.admin()).to.eq(signers.admin.address);
    expect(await contract.deadline()).to.eq(BigInt(deadline));
    expect(await contract.revealed()).to.eq(false);
  });

  it("rejects bids from non-registered addresses", async function () {
    const stranger = (await ethers.getSigners())[4];
    const enc = await fhevm
      .createEncryptedInput(contractAddress, stranger.address)
      .add32(100)
      .encrypt();
    await expect(
      contract.connect(stranger).submitBid(enc.handles[0], enc.inputProof),
    ).to.be.revertedWith("not a registered bidder");
  });

  it("rejects bids submitted after the deadline", async function () {
    await advancePastDeadline();
    const enc = await fhevm
      .createEncryptedInput(contractAddress, signers.alice.address)
      .add32(100)
      .encrypt();
    await expect(
      contract.connect(signers.alice).submitBid(enc.handles[0], enc.inputProof),
    ).to.be.revertedWith("auction closed");
  });

  it("reveal() reverts before deadline; non-admin reverts after deadline; double-call reverts", async function () {
    await expect(contract.connect(signers.admin).reveal()).to.be.revertedWith("too early");

    await advancePastDeadline();

    await expect(contract.connect(signers.alice).reveal()).to.be.revertedWith("not admin");

    await (await contract.connect(signers.admin).reveal()).wait();

    await expect(contract.connect(signers.admin).reveal()).to.be.revertedWith("already revealed");
  });

  it("happy path: 3 bids of 100 / 250 / 175 → revealed winning bid is 250", async function () {
    await submit(signers.alice, 100);
    await submit(signers.bob, 250);
    await submit(signers.carol, 175);

    await advancePastDeadline();
    await (await contract.connect(signers.admin).reveal()).wait();

    const handle = await contract.getWinningBid();
    const winning = await fhevm.publicDecryptEuint(FhevmType.euint32, handle);
    expect(winning).to.eq(250n);
  });

  it("losing bidders cannot decrypt other bidders' bids; their own bid is readable", async function () {
    await submit(signers.alice, 100);
    await submit(signers.bob, 250);
    await submit(signers.carol, 175);

    // Each bidder can decrypt their own bid via the per-bidder ACL grant.
    const aliceHandle = await contract.bids(signers.alice.address);
    const aliceBid = await fhevm.userDecryptEuint(
      FhevmType.euint32,
      aliceHandle,
      contractAddress,
      signers.alice,
    );
    expect(aliceBid).to.eq(100n);

    // Carol cannot decrypt Alice's bid — no ACL.
    await expect(
      fhevm.userDecryptEuint(FhevmType.euint32, aliceHandle, contractAddress, signers.carol),
    ).to.be.rejected;
  });

  it("getWinningBid() reverts before reveal", async function () {
    await expect(contract.getWinningBid()).to.be.revertedWith("not yet revealed");
  });
});
