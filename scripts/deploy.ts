import { ethers } from "hardhat";

async function main() {
  console.log("🚀 Deploying Truth Poll contracts to Polygon...\n");

  const [deployer] = await ethers.getSigners();
  console.log("Deploying contracts with account:", deployer.address);
  console.log("Account balance:", ethers.formatEther(await ethers.provider.getBalance(deployer.address)), "MATIC\n");

  // Contract addresses
  // Native USDC with EIP-2612 permit support
  const POLYGON_USDC = "0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359";
  const BACKEND_ATTESTER = process.env.BACKEND_ATTESTER_ADDRESS || deployer.address;
  const TREASURY = process.env.TREASURY_ADDRESS || deployer.address;
  const TRUSTED_RELAYER = process.env.RELAYER_ADDRESS || process.env.TRUSTED_RELAYER_ADDRESS || deployer.address;

  console.log("Configuration:");
  console.log("- USDC:", POLYGON_USDC);
  console.log("- Backend Attester:", BACKEND_ATTESTER);
  console.log("- Treasury:", TREASURY);
  console.log("- Trusted Relayer:", TRUSTED_RELAYER);
  console.log();

  // 1. Deploy VeriffAttester
  console.log("📝 Deploying VeriffAttester...");
  const VeriffAttester = await ethers.getContractFactory("VeriffAttester");
  const veriffAttester = await VeriffAttester.deploy(BACKEND_ATTESTER);
  await veriffAttester.waitForDeployment();
  const veriffAttesterAddress = await veriffAttester.getAddress();
  console.log("✅ VeriffAttester deployed to:", veriffAttesterAddress);
  console.log();

  // 2. Deploy PollFactory
  console.log("📝 Deploying PollFactory...");
  const PollFactory = await ethers.getContractFactory("PollFactory");
  const pollFactory = await PollFactory.deploy(
    POLYGON_USDC,
    veriffAttesterAddress,
    TREASURY,
    TRUSTED_RELAYER
  );
  await pollFactory.waitForDeployment();
  const pollFactoryAddress = await pollFactory.getAddress();
  console.log("✅ PollFactory deployed to:", pollFactoryAddress);
  console.log();

  // Summary
  console.log("=" .repeat(50));
  console.log("🎉 Deployment Complete!");
  console.log("=" .repeat(50));
  console.log("\nContract Addresses:");
  console.log("-------------------");
  console.log("VeriffAttester:", veriffAttesterAddress);
  console.log("PollFactory:", pollFactoryAddress);
  console.log();

  console.log("Configuration:");
  console.log("--------------");
  console.log("USDC:", POLYGON_USDC);
  console.log("Backend Attester:", BACKEND_ATTESTER);
  console.log("Treasury:", TREASURY);
  console.log("Trusted Relayer:", TRUSTED_RELAYER);
  console.log();

  console.log("Next steps:");
  console.log("-----------");
  console.log("1. Verify contracts on Polygonscan:");
  console.log(`   npx hardhat verify --network polygon ${veriffAttesterAddress} "${BACKEND_ATTESTER}"`);
  console.log(`   npx hardhat verify --network polygon ${pollFactoryAddress} "${POLYGON_USDC}" "${veriffAttesterAddress}" "${TREASURY}" "${TRUSTED_RELAYER}"`);
  console.log();
  console.log("2. Update .env with contract addresses");
  console.log("3. Grant USDC approval to PollFactory for poll creation");
  console.log("4. Use backend service to create attestations");
  console.log();
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
