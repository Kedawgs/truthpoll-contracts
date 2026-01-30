import { ethers } from "hardhat";

/**
 * @deprecated This script is deprecated and will not work with the current PollFactory contract.
 *
 * The PollFactory contract now requires EIP-712 signatures for gasless poll creation.
 * Poll creation should be done through the frontend which generates signatures,
 * and the backend relayer which submits them on-chain.
 *
 * To create polls, use the web interface at /create or the tRPC API.
 *
 * NOTE: All polls now have a fixed 30-day duration (no endTime parameter).
 */
async function main() {
  console.error("❌ This script is deprecated!");
  console.error("");
  console.error("The PollFactory contract now requires EIP-712 signatures for poll creation.");
  console.error("Poll creation should be done through:");
  console.error("  1. The web interface at /create");
  console.error("  2. The tRPC API via the backend relayer");
  console.error("");
  console.error("All polls now have a fixed 30-day duration.");
  process.exit(1);

  // Legacy code below - kept for reference only
  console.log("Creating example poll...\n");

  const [creator] = await ethers.getSigners();
  console.log("Creator address:", creator.address);

  // Get deployed contracts
  const POLL_FACTORY_ADDRESS = process.env.POLL_FACTORY_ADDRESS || "";
  // Native USDC with EIP-2612 permit support
  const USDC_ADDRESS = "0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359";

  if (!POLL_FACTORY_ADDRESS) {
    throw new Error("POLL_FACTORY_ADDRESS not set in .env");
  }

  const pollFactory = await ethers.getContractAt("PollFactory", POLL_FACTORY_ADDRESS);
  const usdc = await ethers.getContractAt(
    "@openzeppelin/contracts/token/ERC20/IERC20.sol:IERC20",
    USDC_ADDRESS
  );

  // Poll parameters
  const question = "Will Bitcoin reach $100,000 by end of 2025?";
  const options = ["Yes", "No"];
  const maxVotes = 100;
  const rewardPerVote = ethers.parseUnits("1", 6); // 1 USDC per vote
  const endTime = Math.floor(Date.now() / 1000) + 7 * 24 * 60 * 60; // 7 days from now

  // Calculate costs
  const fee = await pollFactory.calculateFee(maxVotes);
  const rewardPool = rewardPerVote * BigInt(maxVotes);
  const totalCost = fee + rewardPool;

  console.log("Poll Details:");
  console.log("-------------");
  console.log("Question:", question);
  console.log("Options:", options.join(", "));
  console.log("Max Votes:", maxVotes);
  console.log("Reward Per Vote:", ethers.formatUnits(rewardPerVote, 6), "USDC");
  console.log();

  console.log("Cost Breakdown:");
  console.log("---------------");
  console.log("Factory Fee:", ethers.formatUnits(fee, 6), "USDC");
  console.log("Reward Pool:", ethers.formatUnits(rewardPool, 6), "USDC");
  console.log("Total Cost:", ethers.formatUnits(totalCost, 6), "USDC");
  console.log();

  // Check USDC balance
  const balance = await usdc.balanceOf(creator.address);
  console.log("Creator USDC Balance:", ethers.formatUnits(balance, 6), "USDC");

  if (balance < totalCost) {
    throw new Error(`Insufficient USDC balance. Need ${ethers.formatUnits(totalCost, 6)} USDC`);
  }

  // Approve USDC
  console.log("\n📝 Approving USDC...");
  const approveTx = await usdc.approve(POLL_FACTORY_ADDRESS, totalCost);
  await approveTx.wait();
  console.log("✅ USDC approved");

  // Create poll
  console.log("\n📝 Creating poll...");
  const tx = await pollFactory.createPoll(
    question,
    options,
    maxVotes,
    rewardPerVote,
    endTime
  );
  const receipt = await tx.wait();

  // Get poll address from event
  const event = receipt?.logs.find((log: any) => {
    try {
      const parsed = pollFactory.interface.parseLog(log);
      return parsed?.name === "PollCreated";
    } catch {
      return false;
    }
  });

  if (event) {
    const parsed = pollFactory.interface.parseLog(event);
    const pollAddress = parsed?.args[0];
    const pollId = parsed?.args[1];

    console.log("✅ Poll created successfully!");
    console.log("\nPoll Info:");
    console.log("----------");
    console.log("Poll ID:", pollId.toString());
    console.log("Poll Address:", pollAddress);
    console.log("Transaction Hash:", receipt?.hash);
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
