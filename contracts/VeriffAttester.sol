// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./base/Timelocked.sol";

/**
 * @title VeriffAttester
 * @notice Manages verification attestations for users who complete Veriff KYC
 * @dev Attestations can be created and revoked by authorized backend service
 * @custom:security-contact security@truthpoll.com
 */
contract VeriffAttester is Ownable, Timelocked {
    /// @notice Attestation data structure
    struct Attestation {
        bool exists;              // Whether attestation was ever created
        bool verified;            // Current verification status
        bool revoked;             // Whether attestation was revoked
        uint256 verifiedAt;       // Timestamp of verification
        uint256 revokedAt;        // Timestamp of revocation (0 if not revoked)
        string revocationReason;  // Reason for revocation (empty if not revoked)
        bytes32 verificationCommitment; // Privacy-safe audit trail: keccak256(sessionId + salt)
    }

    /// @notice Mapping of user address to their attestation
    mapping(address => Attestation) public attestations;

    /// @notice Address authorized to create and revoke attestations (backend service)
    address public authorizedAttester;

    /// @notice Operation identifier for timelock
    string private constant OP_SET_ATTESTER = "setAuthorizedAttester";

    /// @notice Emitted when a new attestation is created
    event AttestationCreated(address indexed wallet, uint256 verifiedAt, bytes32 verificationCommitment);

    /// @notice Emitted when an attestation is revoked
    event AttestationRevoked(
        address indexed wallet,
        string reason,
        uint256 revokedAt
    );

    /// @notice Emitted when authorized attester address is changed
    event AuthorizedAttesterUpdated(
        address indexed oldAttester,
        address indexed newAttester
    );

    /// @notice Emitted when an attestation is reinstated
    event AttestationReinstated(address indexed wallet, uint256 reinstatedAt);

    /// @notice Thrown when caller is not the authorized attester
    error UnauthorizedAttester();

    /// @notice Thrown when attempting to create duplicate attestation
    error AttestationAlreadyExists();

    /// @notice Thrown when attempting to revoke non-existent attestation
    error AttestationDoesNotExist();

    /// @notice Thrown when attempting to revoke already revoked attestation
    error AttestationAlreadyRevoked();

    /// @notice Thrown when attempting to reinstate non-revoked attestation
    error AttestationNotRevoked();

    /**
     * @notice Restricts function access to authorized attester only
     */
    modifier onlyAuthorized() {
        if (msg.sender != authorizedAttester) revert UnauthorizedAttester();
        _;
    }

    /**
     * @notice Initialize contract with owner and authorized attester
     * @param _authorizedAttester Address of backend service authorized to create/revoke attestations
     */
    constructor(address _authorizedAttester) Ownable(msg.sender) {
        require(_authorizedAttester != address(0), "Invalid attester address");
        authorizedAttester = _authorizedAttester;
    }

    /**
     * @notice Create a new verification attestation for a user with privacy-safe commitment
     * @dev Can only be called by authorized attester (backend service)
     * @dev Reverts if attestation already exists for this user
     * @param user Address of the user who completed Veriff KYC
     * @param verificationCommitment Privacy-safe hash: keccak256(veriffSessionId + salt)
     *        This reveals nothing on-chain but allows proving the link during legal audits
     *
     * SECURITY: This function should only be called after successful Veriff verification
     * PRIVACY: Commitment is one-way hash - cannot be reversed to session ID without salt
     */
    function createAttestation(address user, bytes32 verificationCommitment) external onlyAuthorized {
        if (attestations[user].exists) revert AttestationAlreadyExists();

        attestations[user] = Attestation({
            exists: true,
            verified: true,
            revoked: false,
            verifiedAt: block.timestamp,
            revokedAt: 0,
            revocationReason: "",
            verificationCommitment: verificationCommitment
        });

        emit AttestationCreated(user, block.timestamp, verificationCommitment);
    }

    /**
     * @notice Create a new verification attestation without commitment (legacy)
     * @dev For backwards compatibility - new calls should use version with commitment
     * @param user Address of the user who completed Veriff KYC
     */
    function createAttestation(address user) external onlyAuthorized {
        if (attestations[user].exists) revert AttestationAlreadyExists();

        attestations[user] = Attestation({
            exists: true,
            verified: true,
            revoked: false,
            verifiedAt: block.timestamp,
            revokedAt: 0,
            revocationReason: "",
            verificationCommitment: bytes32(0)
        });

        emit AttestationCreated(user, block.timestamp, bytes32(0));
    }

    /**
     * @notice Revoke an existing attestation
     * @dev Can only be called by authorized attester (backend service)
     * @dev Revocation can be undone via reinstateAttestation()
     * @param user Address of the user whose attestation should be revoked
     * @param reason Human-readable reason for revocation (for audit trail)
     *
     * SECURITY: Revoked users cannot vote in any future polls
     * SECURITY: Past votes remain immutable (not affected by revocation)
     */
    function revokeAttestation(
        address user,
        string calldata reason
    ) external onlyAuthorized {
        Attestation storage attestation = attestations[user];

        if (!attestation.exists) revert AttestationDoesNotExist();
        if (attestation.revoked) revert AttestationAlreadyRevoked();

        attestation.revoked = true;
        attestation.revokedAt = block.timestamp;
        attestation.revocationReason = reason;

        emit AttestationRevoked(user, reason, block.timestamp);
    }

    /**
     * @notice Reinstate a revoked attestation
     * @dev Can only be called by authorized attester (backend service)
     * @dev Only works for previously revoked attestations
     * @param user Address of the user whose attestation should be reinstated
     *
     * SECURITY: Only authorized attester can call this
     * SECURITY: Original verifiedAt timestamp is preserved
     */
    function reinstateAttestation(address user) external onlyAuthorized {
        Attestation storage attestation = attestations[user];

        if (!attestation.exists) revert AttestationDoesNotExist();
        if (!attestation.revoked) revert AttestationNotRevoked();

        attestation.revoked = false;
        attestation.revokedAt = 0;
        attestation.revocationReason = "";

        emit AttestationReinstated(user, block.timestamp);
    }

    /**
     * @notice Check if a user has a valid, non-revoked attestation
     * @param user Address to check
     * @return bool True if user is verified and not revoked
     *
     * SECURITY: This is the primary function called by Poll contracts
     * SECURITY: Returns false if: never verified, or revoked
     */
    function isVerified(address user) external view returns (bool) {
        Attestation memory attestation = attestations[user];
        return attestation.exists && attestation.verified && !attestation.revoked;
    }

    /**
     * @notice Get full attestation details for a user
     * @param user Address to query
     * @return Attestation struct with all fields
     */
    function getAttestation(
        address user
    ) external view returns (Attestation memory) {
        return attestations[user];
    }

    // ========== TIMELOCKED ADMIN FUNCTIONS ==========

    /**
     * @notice Propose a new authorized attester address (starts 24-hour timelock)
     * @dev Only owner can call. Execute after TIMELOCK_DELAY (24 hours).
     * @param newAttester New address to authorize
     *
     * SECURITY: Use with caution - changing attester affects all attestation operations
     */
    function proposeAuthorizedAttester(address newAttester) external onlyOwner {
        require(newAttester != address(0), "Invalid attester address");
        _propose(OP_SET_ATTESTER, newAttester);
    }

    /**
     * @notice Execute authorized attester update after timelock (24 hours)
     * @param newAttester The attester address that was proposed
     */
    function executeAuthorizedAttester(address newAttester) external onlyOwner {
        _validateProposal(OP_SET_ATTESTER, newAttester);

        address oldAttester = authorizedAttester;
        authorizedAttester = newAttester;

        _markExecuted(OP_SET_ATTESTER, newAttester);
        emit AuthorizedAttesterUpdated(oldAttester, newAttester);
    }

    /**
     * @notice Cancel a pending authorized attester proposal
     * @param newAttester The attester address that was proposed
     */
    function cancelAuthorizedAttesterProposal(address newAttester) external onlyOwner {
        _cancel(OP_SET_ATTESTER, newAttester);
    }
}
