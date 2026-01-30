// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IVeriffAttester
 * @notice Interface for VeriffAttester contract
 * @dev Used by Poll contracts to verify user attestations
 */
interface IVeriffAttester {
    /**
     * @notice Check if a user has a valid, non-revoked attestation
     * @param user Address to check
     * @return bool True if user is verified and not revoked
     */
    function isVerified(address user) external view returns (bool);
}
