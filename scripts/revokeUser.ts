import { ethers } from "hardhat";

async function main() {
  console.log("Revoking attestation for user...\n");

  const [attester] = await ethers.getSigners();
  console.log("Attester address:", attester.address);

  // Get parameters
  const VERIFF_ATTESTER_ADDRESS = process.env.VERIFF_ATTESTER_ADDRESS || "";
  const USER_ADDRESS = process.env.USER_ADDRESS || "";
  const REVOCATION_REASON = process.env.REVOCATION_REASON || "Manual revocation";

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
  if (authorizedAttester.toLowerCase() !== attester.address.toLowerCase()) {
    throw new Error("Signer is not the authorized attester");
  }

  // Check current status
  const existingAttestation = await veriffAttester.getAttestation(USER_ADDRESS);
  if (!existingAttestation.exists) {
    throw new Error("User does not have an attestation");
  }

  if (existingAttestation.revoked) {
    console.log("⚠️  Attestation is already revoked:");
    console.log("Revoked At:", new Date(Number(existingAttestation.revokedAt) * 1000).toLocaleString());
    console.log("Reason:", existingAttestation.revocationReason);
    return;
  }

  console.log("Current Status:");
  console.log("--------------");
  console.log("User:", USER_ADDRESS);
  console.log("Verified:", existingAttestation.verified);
  console.log("Verified At:", new Date(Number(existingAttestation.verifiedAt) * 1000).toLocaleString());

  // Revoke attestation
  console.log("\n📝 Revoking attestation...");
  console.log("Reason:", REVOCATION_REASON);
  const tx = await veriffAttester.revokeAttestation(USER_ADDRESS, REVOCATION_REASON);
  const receipt = await tx.wait();

  console.log("✅ Attestation revoked successfully!");
  console.log("\nTransaction Details:");
  console.log("-------------------");
  console.log("Transaction Hash:", receipt?.hash);
  console.log("Block Number:", receipt?.blockNumber);

  // Verify revocation
  const isVerified = await veriffAttester.isVerified(USER_ADDRESS);
  console.log("\nRevocation Status:");
  console.log("-----------------");
  console.log("Is Verified:", isVerified); // Should be false
  console.log("Can Vote:", isVerified ? "Yes" : "No");

  const attestation = await veriffAttester.getAttestation(USER_ADDRESS);
  console.log("Revoked At:", new Date(Number(attestation.revokedAt) * 1000).toLocaleString());
  console.log("Reason:", attestation.revocationReason);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
