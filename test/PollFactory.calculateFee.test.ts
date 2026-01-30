import { expect } from "chai";
import { ethers } from "hardhat";
import { PollFactory, VeriffAttester } from "../typechain-types";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";

describe("PollFactory.calculateFee - Progressive Bracket Pricing", function () {
  let pollFactory: PollFactory;
  let veriffAttester: VeriffAttester;
  let mockUsdc: any;
  let owner: HardhatEthersSigner;
  let attester: HardhatEthersSigner;
  let treasury: HardhatEthersSigner;
  let relayer: HardhatEthersSigner;

  // USDC has 6 decimals
  const USDC_DECIMALS = 6;
  const toUsdc = (amount: number) => BigInt(Math.round(amount * 10 ** USDC_DECIMALS));

  // Fee tiers (in USDC with 6 decimals)
  const TIER1_FEE = toUsdc(0.10); // $0.10 per vote for first 10
  const TIER2_FEE = toUsdc(0.05); // $0.05 per vote for next 90 (11-100)
  const TIER3_FEE = toUsdc(0.02); // $0.02 per vote for next 900 (101-1000)
  const TIER4_FEE = toUsdc(0.01); // $0.01 per vote for 1001+

  // Pre-calculated cumulative fees at tier boundaries
  const TIER1_CUMULATIVE = toUsdc(1.00);    // 10 × $0.10 = $1.00
  const TIER2_CUMULATIVE = toUsdc(5.50);    // $1.00 + 90 × $0.05 = $5.50
  const TIER3_CUMULATIVE = toUsdc(23.50);   // $5.50 + 900 × $0.02 = $23.50

  beforeEach(async function () {
    [owner, attester, treasury, relayer] = await ethers.getSigners();

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

  describe("Tier 1: 0-10 votes ($0.10 per vote)", function () {
    it("Should calculate 0 votes = $0.00", async function () {
      const fee = await pollFactory.calculateFee(0);
      expect(fee).to.equal(toUsdc(0.00));
    });

    it("Should calculate 1 vote = $0.10", async function () {
      const fee = await pollFactory.calculateFee(1);
      expect(fee).to.equal(toUsdc(0.10));
    });

    it("Should calculate 5 votes = $0.50", async function () {
      const fee = await pollFactory.calculateFee(5);
      expect(fee).to.equal(toUsdc(0.50));
    });

    it("Should calculate 10 votes = $1.00 (tier boundary)", async function () {
      const fee = await pollFactory.calculateFee(10);
      expect(fee).to.equal(TIER1_CUMULATIVE);
      expect(fee).to.equal(toUsdc(1.00));
    });
  });

  describe("Tier 2: 11-100 votes ($0.05 per additional vote)", function () {
    it("Should calculate 11 votes = $1.05 (first vote in tier 2)", async function () {
      const fee = await pollFactory.calculateFee(11);
      // $1.00 + 1 × $0.05 = $1.05
      const expected = TIER1_CUMULATIVE + 1n * TIER2_FEE;
      expect(fee).to.equal(expected);
      expect(fee).to.equal(toUsdc(1.05));
    });

    it("Should calculate 50 votes = $3.00", async function () {
      const fee = await pollFactory.calculateFee(50);
      // $1.00 + 40 × $0.05 = $3.00
      const expected = TIER1_CUMULATIVE + 40n * TIER2_FEE;
      expect(fee).to.equal(expected);
      expect(fee).to.equal(toUsdc(3.00));
    });

    it("Should calculate 100 votes = $5.50 (tier boundary)", async function () {
      const fee = await pollFactory.calculateFee(100);
      expect(fee).to.equal(TIER2_CUMULATIVE);
      expect(fee).to.equal(toUsdc(5.50));
    });
  });

  describe("Tier 3: 101-1000 votes ($0.02 per additional vote)", function () {
    it("Should calculate 101 votes = $5.52 (first vote in tier 3)", async function () {
      const fee = await pollFactory.calculateFee(101);
      // $5.50 + 1 × $0.02 = $5.52
      const expected = TIER2_CUMULATIVE + 1n * TIER3_FEE;
      expect(fee).to.equal(expected);
      expect(fee).to.equal(toUsdc(5.52));
    });

    it("Should calculate 500 votes = $13.50", async function () {
      const fee = await pollFactory.calculateFee(500);
      // $5.50 + 400 × $0.02 = $13.50
      const expected = TIER2_CUMULATIVE + 400n * TIER3_FEE;
      expect(fee).to.equal(expected);
      expect(fee).to.equal(toUsdc(13.50));
    });

    it("Should calculate 1000 votes = $23.50 (tier boundary)", async function () {
      const fee = await pollFactory.calculateFee(1000);
      expect(fee).to.equal(TIER3_CUMULATIVE);
      expect(fee).to.equal(toUsdc(23.50));
    });
  });

  describe("Tier 4: 1001+ votes ($0.01 per additional vote)", function () {
    it("Should calculate 1001 votes = $23.51 (first vote in tier 4)", async function () {
      const fee = await pollFactory.calculateFee(1001);
      // $23.50 + 1 × $0.01 = $23.51
      const expected = TIER3_CUMULATIVE + 1n * TIER4_FEE;
      expect(fee).to.equal(expected);
      expect(fee).to.equal(toUsdc(23.51));
    });

    it("Should calculate 5000 votes = $63.50", async function () {
      const fee = await pollFactory.calculateFee(5000);
      // $23.50 + 4000 × $0.01 = $63.50
      const expected = TIER3_CUMULATIVE + 4000n * TIER4_FEE;
      expect(fee).to.equal(expected);
      expect(fee).to.equal(toUsdc(63.50));
    });

    it("Should calculate 10000 votes = $113.50", async function () {
      const fee = await pollFactory.calculateFee(10000);
      // $23.50 + 9000 × $0.01 = $113.50
      const expected = TIER3_CUMULATIVE + 9000n * TIER4_FEE;
      expect(fee).to.equal(expected);
      expect(fee).to.equal(toUsdc(113.50));
    });

    it("Should calculate 100000 votes = $1013.50", async function () {
      const fee = await pollFactory.calculateFee(100000);
      // $23.50 + 99000 × $0.01 = $1013.50
      const expected = TIER3_CUMULATIVE + 99000n * TIER4_FEE;
      expect(fee).to.equal(expected);
      expect(fee).to.equal(toUsdc(1013.50));
    });
  });

  describe("Regression Tests: Price Inversion Bugs (OLD BEHAVIOR)", function () {
    /**
     * These tests verify the bug is FIXED.
     * Old (buggy) behavior applied a single tier rate to ALL votes:
     * - 100 votes = 100 × $0.05 = $5.00
     * - 101 votes = 101 × $0.02 = $2.02 (cheaper than 100! BUG!)
     *
     * New (progressive) behavior:
     * - 100 votes = $1.00 + $4.50 = $5.50
     * - 101 votes = $5.50 + $0.02 = $5.52 (more than 100, correct!)
     */

    it("101 votes should cost MORE than 100 votes (not less)", async function () {
      const fee100 = await pollFactory.calculateFee(100);
      const fee101 = await pollFactory.calculateFee(101);

      // In old buggy code: fee101 (101 × $0.02 = $2.02) < fee100 (100 × $0.05 = $5.00)
      // In fixed code: fee101 ($5.52) > fee100 ($5.50)
      expect(fee101).to.be.gt(fee100);

      // Verify exact values
      expect(fee100).to.equal(toUsdc(5.50));
      expect(fee101).to.equal(toUsdc(5.52));
    });

    it("11 votes should cost MORE than 10 votes (not less)", async function () {
      const fee10 = await pollFactory.calculateFee(10);
      const fee11 = await pollFactory.calculateFee(11);

      // In old buggy code: fee11 (11 × $0.05 = $0.55) < fee10 (10 × $0.10 = $1.00)
      // In fixed code: fee11 ($1.05) > fee10 ($1.00)
      expect(fee11).to.be.gt(fee10);

      // Verify exact values
      expect(fee10).to.equal(toUsdc(1.00));
      expect(fee11).to.equal(toUsdc(1.05));
    });

    it("1001 votes should cost MORE than 1000 votes (not less)", async function () {
      const fee1000 = await pollFactory.calculateFee(1000);
      const fee1001 = await pollFactory.calculateFee(1001);

      // In old buggy code: fee1001 (1001 × $0.01 = $10.01) < fee1000 (1000 × $0.02 = $20.00)
      // In fixed code: fee1001 ($23.51) > fee1000 ($23.50)
      expect(fee1001).to.be.gt(fee1000);

      // Verify exact values
      expect(fee1000).to.equal(toUsdc(23.50));
      expect(fee1001).to.equal(toUsdc(23.51));
    });
  });

  describe("Monotonically Increasing Fee Verification", function () {
    it("Fee should always increase or stay same as votes increase (comprehensive)", async function () {
      const testPoints = [
        0, 1, 5, 9, 10, 11, 12, 50, 99, 100, 101, 102, 500,
        999, 1000, 1001, 1002, 5000, 10000
      ];

      let previousFee = 0n;
      for (const votes of testPoints) {
        const fee = await pollFactory.calculateFee(votes);
        expect(fee).to.be.gte(
          previousFee,
          `Fee for ${votes} votes (${fee}) should be >= fee for previous votes (${previousFee})`
        );
        previousFee = fee;
      }
    });

    it("Fee should strictly increase for each additional vote", async function () {
      // Test around tier boundaries where bugs typically occur
      const ranges = [
        [1, 15],    // Around tier 1/2 boundary
        [95, 105],  // Around tier 2/3 boundary
        [995, 1005] // Around tier 3/4 boundary
      ];

      for (const [start, end] of ranges) {
        for (let votes = start; votes < end; votes++) {
          const fee1 = await pollFactory.calculateFee(votes);
          const fee2 = await pollFactory.calculateFee(votes + 1);
          expect(fee2).to.be.gt(
            fee1,
            `Fee for ${votes + 1} votes should be > fee for ${votes} votes`
          );
        }
      }
    });
  });

  describe("Edge Cases", function () {
    it("Should handle 0 votes gracefully", async function () {
      const fee = await pollFactory.calculateFee(0);
      expect(fee).to.equal(0n);
    });

    it("Should handle very large vote counts", async function () {
      const fee = await pollFactory.calculateFee(1000000);
      // $23.50 + 999000 × $0.01 = $10,013.50
      const expected = TIER3_CUMULATIVE + 999000n * TIER4_FEE;
      expect(fee).to.equal(expected);
      expect(fee).to.equal(toUsdc(10013.50));
    });

    it("Should not overflow with max uint256 reasonable value", async function () {
      // Test with 10 million votes (reasonable upper bound)
      const fee = await pollFactory.calculateFee(10000000);
      // $23.50 + 9,999,000 × $0.01 = $100,013.50
      const expected = TIER3_CUMULATIVE + 9999000n * TIER4_FEE;
      expect(fee).to.equal(expected);
    });
  });

  describe("Fee Comparison Table (Documentation Verification)", function () {
    /**
     * Verify the fee comparison table from the plan:
     * | Votes | Old (Flat) | New (Progressive) |
     * |-------|------------|-------------------|
     * | 10    | $1.00      | $1.00             |
     * | 11    | $0.55 BUG  | $1.05             |
     * | 100   | $5.00      | $5.50             |
     * | 101   | $2.02 BUG  | $5.52             |
     * | 500   | $10.00     | $13.50            |
     * | 1000  | $20.00     | $23.50            |
     * | 5000  | $50.00     | $63.50            |
     */

    const expectedFees: [number, number][] = [
      [10, 1.00],
      [11, 1.05],
      [100, 5.50],
      [101, 5.52],
      [500, 13.50],
      [1000, 23.50],
      [5000, 63.50],
    ];

    for (const [votes, expectedUsd] of expectedFees) {
      it(`Should calculate ${votes} votes = $${expectedUsd.toFixed(2)}`, async function () {
        const fee = await pollFactory.calculateFee(votes);
        expect(fee).to.equal(toUsdc(expectedUsd));
      });
    }
  });

  describe("Gas Efficiency", function () {
    it("Should execute calculateFee with reasonable gas", async function () {
      // Gas estimation for pure function calls
      // The function uses pre-calculated cumulative values for efficiency
      const testCases = [10, 100, 1000, 10000];

      for (const votes of testCases) {
        // For pure functions, we can't directly measure gas, but we can verify
        // the function completes successfully
        const fee = await pollFactory.calculateFee(votes);
        expect(fee).to.be.gt(0n);
      }
    });
  });
});
