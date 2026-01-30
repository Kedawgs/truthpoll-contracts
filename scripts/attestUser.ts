import { ethers } from "hardhat";

async function main() {
  console.log("Creating attestation for user...\n");

  const [attester] = await ethers.getSigners();
  console.log("Attester address:", attester.address);

  // Get deployed contract
  const VERIFF_ATTESTER_ADDRESS = process.env.VERIFF_ATTESTER_ADDRESS || "";
  const USER_ADDRESS = process.env.USER_ADDRESS || "";

  if (!VERIFF_ATTESTER_ADDRESS) {
    throw new Error("VERIFF_ATTESTER_ADDRESS not set in .env");
  }

  if (!USER_ADDRESS) {
    throw new Error("USER_ADDRESS not set in .env");
  }

  const veriffAttester = await ethers.getContractAt(
    "VeriffAttester",
    VERIFF_ATTESTER_ADDRESS
  );

  // Check if attester is authorized
  const authorizedAttester = await veriffAttester.authorizedAttester();
  console.log("Authorized Attester:", authorizedAttester);
  console.log("Current Signer:", attester.address);

  if (authorizedAttester.toLowerCase() !== attester.address.toLowerCase()) {
    throw new Error("Signer is not the authorized attester");
  }

  // Check if user already has attestation
  const existingAttestation = await veriffAttester.getAttestation(USER_ADDRESS);
  if (existingAttestation.exists) {
    console.log("\n⚠️  User already has an attestation:");
    console.log("Verified:", existingAttestation.verified);
    console.log("Revoked:", existingAttestation.revoked);
    console.log("Verified At:", new Date(Number(existingAttestation.verifiedAt) * 1000).toLocaleString());
    if (existingAttestation.revoked) {
      console.log("Revoked At:", new Date(Number(existingAttestation.revokedAt) * 1000).toLocaleString());
      console.log("Revocation Reason:", existingAttestation.revocationReason);
    }
    return;
  }

  // Create attestation
  console.log("\n📝 Creating attestation for:", USER_ADDRESS);
  const tx = await veriffAttester.createAttestation(USER_ADDRESS);
  const receipt = await tx.wait();

  console.log("✅ Attestation created successfully!");
  console.log("\nTransaction Details:");
  console.log("-------------------");
  console.log("Transaction Hash:", receipt?.hash);
  console.log("Block Number:", receipt?.blockNumber);

  // Verify attestation
  const isVerified = await veriffAttester.isVerified(USER_ADDRESS);
  console.log("\nVerification Status:");
  console.log("-------------------");
  console.log("Is Verified:", isVerified);

  const attestation = await veriffAttester.getAttestation(USER_ADDRESS);
  console.log("Verified At:", new Date(Number(attestation.verifiedAt) * 1000).toLocaleString());
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
