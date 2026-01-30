import { expect } from "chai";
import { ethers } from "hardhat";
import { time } from "@nomicfoundation/hardhat-network-helpers";
import { PollFactory, VeriffAttester } from "../typechain-types";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";

describe("Timelocked Admin Functions", function () {
  let pollFactory: PollFactory;
  let veriffAttester: VeriffAttester;
  let mockUsdc: any;
  let owner: HardhatEthersSigner;
  let attester: HardhatEthersSigner;
  let treasury: HardhatEthersSigner;
  let newTreasury: HardhatEthersSigner;
  let relayer: HardhatEthersSigner;
  let newRelayer: HardhatEthersSigner;
  let refunder: HardhatEthersSigner;
  let unauthorized: HardhatEthersSigner;

  const TIMELOCK_DELAY = 24 * 60 * 60; // 24 hours in seconds
  const PROPOSAL_EXPIRY = 7 * 24 * 60 * 60; // 7 days in seconds

  beforeEach(async function () {
    [owner, attester, treasury, newTreasury, relayer, newRelayer, refunder, unauthorized] =
      await ethers.getSigners();

    // Deploy mock USDC
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    mockUsdc = await MockERC20.deploy("USD Coin", "USDC", 6);
    await mockUsdc.waitForDeployment();

    // Deploy VeriffAttester
    const VeriffAttesterFactory = await ethers.getContractFactory("VeriffAttester");
    veriffAttester = await VeriffAttesterFactory.deploy(attester.address);
    await veriffAttester.waitForDeployment();

    // Deploy PollFactory
    const PollFactoryFactory = await ethers.getContractFactory("PollFactory");
    pollFactory = await PollFactoryFactory.deploy(
      await mockUsdc.getAddress(),
      await veriffAttester.getAddress(),
      treasury.address,
      relayer.address
    );
    await pollFactory.waitForDeployment();
  });

  describe("PollFactory Timelock - Treasury", function () {
    describe("proposeTreasury", function () {
      it("Should emit ProposalCreated event", async function () {
        await expect(pollFactory.connect(owner).proposeTreasury(newTreasury.address))
          .to.emit(pollFactory, "ProposalCreated");
      });

      it("Should revert if not owner", async function () {
        await expect(
          pollFactory.connect(unauthorized).proposeTreasury(newTreasury.address)
        ).to.be.revertedWithCustomError(pollFactory, "OwnableUnauthorizedAccount");
      });

      it("Should revert with zero address", async function () {
        await expect(
          pollFactory.connect(owner).proposeTreasury(ethers.ZeroAddress)
        ).to.be.revertedWith("Invalid treasury address");
      });

      it("Should revert if proposal already pending", async function () {
        await pollFactory.connect(owner).proposeTreasury(newTreasury.address);
        await expect(
          pollFactory.connect(owner).proposeTreasury(newTreasury.address)
        ).to.be.revertedWithCustomError(pollFactory, "ProposalAlreadyPending");
      });
    });

    describe("executeTreasury", function () {
      beforeEach(async function () {
        await pollFactory.connect(owner).proposeTreasury(newTreasury.address);
      });

      it("Should revert before timelock expires", async function () {
        await expect(
          pollFactory.connect(owner).executeTreasury(newTreasury.address)
        ).to.be.revertedWithCustomError(pollFactory, "ProposalNotReady");
      });

      it("Should execute after timelock expires", async function () {
        await time.increase(TIMELOCK_DELAY + 1);

        await expect(pollFactory.connect(owner).executeTreasury(newTreasury.address))
          .to.emit(pollFactory, "TreasuryUpdated")
          .withArgs(treasury.address, newTreasury.address);

        expect(await pollFactory.treasury()).to.equal(newTreasury.address);
      });

      it("Should revert on double execution", async function () {
        await time.increase(TIMELOCK_DELAY + 1);
        await pollFactory.connect(owner).executeTreasury(newTreasury.address);

        await expect(
          pollFactory.connect(owner).executeTreasury(newTreasury.address)
        ).to.be.revertedWithCustomError(pollFactory, "ProposalAlreadyExecuted");
      });

      it("Should revert if proposal expired", async function () {
        await time.increase(TIMELOCK_DELAY + PROPOSAL_EXPIRY + 1);

        await expect(
          pollFactory.connect(owner).executeTreasury(newTreasury.address)
        ).to.be.revertedWithCustomError(pollFactory, "ProposalExpired");
      });

      it("Should revert if proposal does not exist", async function () {
        await time.increase(TIMELOCK_DELAY + 1);

        await expect(
          pollFactory.connect(owner).executeTreasury(unauthorized.address)
        ).to.be.revertedWithCustomError(pollFactory, "ProposalDoesNotExist");
      });
    });

    describe("cancelTreasuryProposal", function () {
      beforeEach(async function () {
        await pollFactory.connect(owner).proposeTreasury(newTreasury.address);
      });

      it("Should cancel pending proposal", async function () {
        await expect(pollFactory.connect(owner).cancelTreasuryProposal(newTreasury.address))
          .to.emit(pollFactory, "ProposalCancelled");
      });

      it("Should prevent execution after cancel", async function () {
        await pollFactory.connect(owner).cancelTreasuryProposal(newTreasury.address);
        await time.increase(TIMELOCK_DELAY + 1);

        await expect(
          pollFactory.connect(owner).executeTreasury(newTreasury.address)
        ).to.be.revertedWithCustomError(pollFactory, "ProposalWasCancelled");
      });

      it("Should allow new proposal after cancel", async function () {
        await pollFactory.connect(owner).cancelTreasuryProposal(newTreasury.address);

        // Should be able to propose again
        await expect(pollFactory.connect(owner).proposeTreasury(newTreasury.address))
          .to.emit(pollFactory, "ProposalCreated");
      });
    });
  });

  describe("PollFactory Timelock - Refunder", function () {
    it("Should allow proposing address(0) to disable refunder", async function () {
      await expect(pollFactory.connect(owner).proposeRefunder(ethers.ZeroAddress))
        .to.emit(pollFactory, "ProposalCreated");

      await time.increase(TIMELOCK_DELAY + 1);

      await pollFactory.connect(owner).executeRefunder(ethers.ZeroAddress);
      expect(await pollFactory.refunder()).to.equal(ethers.ZeroAddress);
    });

    it("Should complete full propose/execute cycle", async function () {
      await pollFactory.connect(owner).proposeRefunder(refunder.address);
      await time.increase(TIMELOCK_DELAY + 1);

      await expect(pollFactory.connect(owner).executeRefunder(refunder.address))
        .to.emit(pollFactory, "RefunderUpdated");

      expect(await pollFactory.refunder()).to.equal(refunder.address);
    });
  });

  describe("PollFactory Timelock - Trusted Relayer", function () {
    it("Should revert with zero address", async function () {
      await expect(
        pollFactory.connect(owner).proposeTrustedRelayer(ethers.ZeroAddress)
      ).to.be.revertedWith("Invalid relayer address");
    });

    it("Should complete full propose/execute cycle", async function () {
      await pollFactory.connect(owner).proposeTrustedRelayer(newRelayer.address);
      await time.increase(TIMELOCK_DELAY + 1);

      await expect(pollFactory.connect(owner).executeTrustedRelayer(newRelayer.address))
        .to.emit(pollFactory, "TrustedRelayerUpdated")
        .withArgs(relayer.address, newRelayer.address);

      expect(await pollFactory.trustedRelayer()).to.equal(newRelayer.address);
    });
  });

  describe("PollFactory - Pause (No Timelock)", function () {
    it("Should pause immediately", async function () {
      await pollFactory.connect(owner).pause();
      expect(await pollFactory.paused()).to.be.true;
    });

    it("Should unpause immediately", async function () {
      await pollFactory.connect(owner).pause();
      await pollFactory.connect(owner).unpause();
      expect(await pollFactory.paused()).to.be.false;
    });
  });

  describe("VeriffAttester Timelock - Authorized Attester", function () {
    describe("proposeAuthorizedAttester", function () {
      it("Should emit ProposalCreated event", async function () {
        await expect(
          veriffAttester.connect(owner).proposeAuthorizedAttester(newRelayer.address)
        ).to.emit(veriffAttester, "ProposalCreated");
      });

      it("Should revert if not owner", async function () {
        await expect(
          veriffAttester.connect(attester).proposeAuthorizedAttester(newRelayer.address)
        ).to.be.revertedWithCustomError(veriffAttester, "OwnableUnauthorizedAccount");
      });

      it("Should revert with zero address", async function () {
        await expect(
          veriffAttester.connect(owner).proposeAuthorizedAttester(ethers.ZeroAddress)
        ).to.be.revertedWith("Invalid attester address");
      });
    });

    describe("executeAuthorizedAttester", function () {
      beforeEach(async function () {
        await veriffAttester.connect(owner).proposeAuthorizedAttester(newRelayer.address);
      });

      it("Should revert before timelock expires", async function () {
        await expect(
          veriffAttester.connect(owner).executeAuthorizedAttester(newRelayer.address)
        ).to.be.revertedWithCustomError(veriffAttester, "ProposalNotReady");
      });

      it("Should execute after timelock expires", async function () {
        await time.increase(TIMELOCK_DELAY + 1);

        await expect(
          veriffAttester.connect(owner).executeAuthorizedAttester(newRelayer.address)
        ).to.emit(veriffAttester, "AuthorizedAttesterUpdated")
          .withArgs(attester.address, newRelayer.address);

        expect(await veriffAttester.authorizedAttester()).to.equal(newRelayer.address);
      });
    });

    describe("cancelAuthorizedAttesterProposal", function () {
      it("Should cancel pending proposal", async function () {
        await veriffAttester.connect(owner).proposeAuthorizedAttester(newRelayer.address);

        await expect(
          veriffAttester.connect(owner).cancelAuthorizedAttesterProposal(newRelayer.address)
        ).to.emit(veriffAttester, "ProposalCancelled");
      });
    });
  });

  describe("Timelock Utility Functions", function () {
    it("getProposalStatus should return correct status", async function () {
      const operationId = ethers.keccak256(
        ethers.solidityPacked(["string", "address"], ["setTreasury", newTreasury.address])
      );

      // Before proposal
      let status = await pollFactory.getProposalStatus(operationId);
      expect(status.exists).to.be.false;

      // After proposal
      await pollFactory.connect(owner).proposeTreasury(newTreasury.address);
      status = await pollFactory.getProposalStatus(operationId);
      expect(status.exists).to.be.true;
      expect(status.executed).to.be.false;
      expect(status.cancelled).to.be.false;

      // After execution
      await time.increase(TIMELOCK_DELAY + 1);
      await pollFactory.connect(owner).executeTreasury(newTreasury.address);
      status = await pollFactory.getProposalStatus(operationId);
      expect(status.executed).to.be.true;
    });

    it("getTimeUntilExecutable should return correct time", async function () {
      const operationId = ethers.keccak256(
        ethers.solidityPacked(["string", "address"], ["setTreasury", newTreasury.address])
      );

      await pollFactory.connect(owner).proposeTreasury(newTreasury.address);

      const timeRemaining = await pollFactory.getTimeUntilExecutable(operationId);
      expect(timeRemaining).to.be.closeTo(BigInt(TIMELOCK_DELAY), BigInt(5)); // Allow 5 second margin

      // After timelock expires
      await time.increase(TIMELOCK_DELAY + 1);
      const timeAfter = await pollFactory.getTimeUntilExecutable(operationId);
      expect(timeAfter).to.equal(0n);
    });
  });
});
