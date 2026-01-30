import { expect } from "chai";
import { ethers } from "hardhat";
import { time } from "@nomicfoundation/hardhat-network-helpers";
import { VeriffAttester } from "../typechain-types";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";

const TIMELOCK_DELAY = 24 * 60 * 60; // 24 hours in seconds

describe("VeriffAttester", function () {
  let veriffAttester: VeriffAttester;
  let owner: HardhatEthersSigner;
  let attester: HardhatEthersSigner;
  let user: HardhatEthersSigner;
  let unauthorized: HardhatEthersSigner;

  beforeEach(async function () {
    [owner, attester, user, unauthorized] = await ethers.getSigners();

    const VeriffAttester = await ethers.getContractFactory("VeriffAttester");
    veriffAttester = await VeriffAttester.deploy(attester.address);
    await veriffAttester.waitForDeployment();
  });

  describe("Deployment", function () {
    it("Should set the correct authorized attester", async function () {
      expect(await veriffAttester.authorizedAttester()).to.equal(attester.address);
    });

    it("Should set the correct owner", async function () {
      expect(await veriffAttester.owner()).to.equal(owner.address);
    });
  });

  describe("Create Attestation", function () {
    it("Should create attestation as authorized attester", async function () {
      const ZERO_BYTES32 = "0x0000000000000000000000000000000000000000000000000000000000000000";
      await expect(veriffAttester.connect(attester).createAttestation(user.address))
        .to.emit(veriffAttester, "AttestationCreated")
        .withArgs(user.address, await ethers.provider.getBlock("latest").then(b => b!.timestamp + 1), ZERO_BYTES32);

      const attestation = await veriffAttester.getAttestation(user.address);
      expect(attestation.exists).to.be.true;
      expect(attestation.verified).to.be.true;
      expect(attestation.revoked).to.be.false;
    });

    it("Should fail if not authorized attester", async function () {
      await expect(
        veriffAttester.connect(unauthorized).createAttestation(user.address)
      ).to.be.revertedWithCustomError(veriffAttester, "UnauthorizedAttester");
    });

    it("Should fail if attestation already exists", async function () {
      await veriffAttester.connect(attester).createAttestation(user.address);
      await expect(
        veriffAttester.connect(attester).createAttestation(user.address)
      ).to.be.revertedWithCustomError(veriffAttester, "AttestationAlreadyExists");
    });

    it("Should return true for isVerified after creation", async function () {
      await veriffAttester.connect(attester).createAttestation(user.address);
      expect(await veriffAttester.isVerified(user.address)).to.be.true;
    });
  });

  describe("Revoke Attestation", function () {
    beforeEach(async function () {
      await veriffAttester.connect(attester).createAttestation(user.address);
    });

    it("Should revoke attestation as authorized attester", async function () {
      const reason = "Failed verification check";
      await expect(veriffAttester.connect(attester).revokeAttestation(user.address, reason))
        .to.emit(veriffAttester, "AttestationRevoked")
        .withArgs(user.address, reason, await ethers.provider.getBlock("latest").then(b => b!.timestamp + 1));

      const attestation = await veriffAttester.getAttestation(user.address);
      expect(attestation.revoked).to.be.true;
      expect(attestation.revocationReason).to.equal(reason);
    });

    it("Should fail if not authorized attester", async function () {
      await expect(
        veriffAttester.connect(unauthorized).revokeAttestation(user.address, "test")
      ).to.be.revertedWithCustomError(veriffAttester, "UnauthorizedAttester");
    });

    it("Should fail if attestation does not exist", async function () {
      await expect(
        veriffAttester.connect(attester).revokeAttestation(unauthorized.address, "test")
      ).to.be.revertedWithCustomError(veriffAttester, "AttestationDoesNotExist");
    });

    it("Should fail if already revoked", async function () {
      await veriffAttester.connect(attester).revokeAttestation(user.address, "first");
      await expect(
        veriffAttester.connect(attester).revokeAttestation(user.address, "second")
      ).to.be.revertedWithCustomError(veriffAttester, "AttestationAlreadyRevoked");
    });

    it("Should return false for isVerified after revocation", async function () {
      await veriffAttester.connect(attester).revokeAttestation(user.address, "test");
      expect(await veriffAttester.isVerified(user.address)).to.be.false;
    });
  });

  describe("Update Authorized Attester (Timelocked)", function () {
    it("Should update attester after timelock", async function () {
      const newAttester = unauthorized.address;

      // Propose
      await veriffAttester.connect(owner).proposeAuthorizedAttester(newAttester);

      // Wait for timelock
      await time.increase(TIMELOCK_DELAY + 1);

      // Execute
      await expect(veriffAttester.connect(owner).executeAuthorizedAttester(newAttester))
        .to.emit(veriffAttester, "AuthorizedAttesterUpdated")
        .withArgs(attester.address, newAttester);

      expect(await veriffAttester.authorizedAttester()).to.equal(newAttester);
    });

    it("Should fail to propose if not owner", async function () {
      await expect(
        veriffAttester.connect(attester).proposeAuthorizedAttester(unauthorized.address)
      ).to.be.revertedWithCustomError(veriffAttester, "OwnableUnauthorizedAccount");
    });

    it("Should fail to propose with zero address", async function () {
      await expect(
        veriffAttester.connect(owner).proposeAuthorizedAttester(ethers.ZeroAddress)
      ).to.be.revertedWith("Invalid attester address");
    });

    it("Should fail to execute before timelock", async function () {
      await veriffAttester.connect(owner).proposeAuthorizedAttester(unauthorized.address);

      await expect(
        veriffAttester.connect(owner).executeAuthorizedAttester(unauthorized.address)
      ).to.be.revertedWithCustomError(veriffAttester, "ProposalNotReady");
    });

    it("Should cancel proposal successfully", async function () {
      await veriffAttester.connect(owner).proposeAuthorizedAttester(unauthorized.address);

      await expect(
        veriffAttester.connect(owner).cancelAuthorizedAttesterProposal(unauthorized.address)
      ).to.emit(veriffAttester, "ProposalCancelled");
    });
  });
});
