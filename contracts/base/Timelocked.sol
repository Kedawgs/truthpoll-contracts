// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title Timelocked
 * @notice Base contract providing 24-hour timelock for sensitive admin functions
 * @dev Inherit this contract and use internal functions to implement propose/execute pattern
 */
abstract contract Timelocked {
    /// @notice Timelock delay: 24 hours
    uint256 public constant TIMELOCK_DELAY = 24 hours;

    /// @notice Maximum time a proposal can remain pending before expiring
    uint256 public constant PROPOSAL_EXPIRY = 7 days;

    /// @notice Struct to track pending changes
    struct TimelockProposal {
        uint256 executableAt;
        bool executed;
        bool cancelled;
    }

    /// @notice Mapping of operation ID to proposal
    mapping(bytes32 => TimelockProposal) public proposals;

    /// @notice Emitted when a new proposal is created
    event ProposalCreated(
        bytes32 indexed operationId,
        string operation,
        address indexed newValue,
        uint256 executableAt
    );

    /// @notice Emitted when a proposal is executed
    event ProposalExecuted(
        bytes32 indexed operationId,
        string operation,
        address indexed newValue
    );

    /// @notice Emitted when a proposal is cancelled
    event ProposalCancelled(bytes32 indexed operationId, string operation);

    /// @notice Thrown when proposal does not exist
    error ProposalDoesNotExist();

    /// @notice Thrown when proposal is not yet executable (timelock not elapsed)
    error ProposalNotReady();

    /// @notice Thrown when proposal has already been executed
    error ProposalAlreadyExecuted();

    /// @notice Thrown when proposal has been cancelled
    error ProposalWasCancelled();

    /// @notice Thrown when proposal has expired
    error ProposalExpired();

    /// @notice Thrown when a proposal for this operation already exists and is pending
    error ProposalAlreadyPending();

    /**
     * @notice Create a unique operation ID from operation name and new value
     * @param operation String identifier of the operation (e.g., "setTreasury")
     * @param newValue The new address value being proposed
     * @return bytes32 Unique hash identifying this specific change
     */
    function _getOperationId(
        string memory operation,
        address newValue
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(operation, newValue));
    }

    /**
     * @notice Propose a timelocked change
     * @dev Starts the 24-hour countdown before execution is allowed
     * @param operation String identifier of the operation
     * @param newValue The new address value being proposed
     * @return operationId The unique ID for tracking this proposal
     */
    function _propose(
        string memory operation,
        address newValue
    ) internal returns (bytes32 operationId) {
        operationId = _getOperationId(operation, newValue);

        TimelockProposal storage proposal = proposals[operationId];

        // Check if there's already an active proposal for this exact change
        if (proposal.executableAt != 0 &&
            !proposal.executed &&
            !proposal.cancelled &&
            block.timestamp < proposal.executableAt + PROPOSAL_EXPIRY) {
            revert ProposalAlreadyPending();
        }

        uint256 executableAt = block.timestamp + TIMELOCK_DELAY;

        proposals[operationId] = TimelockProposal({
            executableAt: executableAt,
            executed: false,
            cancelled: false
        });

        emit ProposalCreated(operationId, operation, newValue, executableAt);

        return operationId;
    }

    /**
     * @notice Check if a proposal is ready for execution
     * @dev Reverts with appropriate error if not ready
     * @param operation String identifier of the operation
     * @param newValue The address value that was proposed
     * @return operationId The validated operation ID
     */
    function _validateProposal(
        string memory operation,
        address newValue
    ) internal view returns (bytes32 operationId) {
        operationId = _getOperationId(operation, newValue);
        TimelockProposal storage proposal = proposals[operationId];

        if (proposal.executableAt == 0) revert ProposalDoesNotExist();
        if (proposal.cancelled) revert ProposalWasCancelled();
        if (proposal.executed) revert ProposalAlreadyExecuted();
        if (block.timestamp < proposal.executableAt) revert ProposalNotReady();
        if (block.timestamp > proposal.executableAt + PROPOSAL_EXPIRY) revert ProposalExpired();

        return operationId;
    }

    /**
     * @notice Mark a proposal as executed
     * @param operation String identifier of the operation
     * @param newValue The address value that was proposed
     */
    function _markExecuted(
        string memory operation,
        address newValue
    ) internal {
        bytes32 operationId = _getOperationId(operation, newValue);
        proposals[operationId].executed = true;

        emit ProposalExecuted(operationId, operation, newValue);
    }

    /**
     * @notice Cancel a pending proposal
     * @dev Can only cancel proposals that haven't been executed
     * @param operation String identifier of the operation
     * @param newValue The address value that was proposed
     */
    function _cancel(
        string memory operation,
        address newValue
    ) internal {
        bytes32 operationId = _getOperationId(operation, newValue);
        TimelockProposal storage proposal = proposals[operationId];

        if (proposal.executableAt == 0) revert ProposalDoesNotExist();
        if (proposal.executed) revert ProposalAlreadyExecuted();
        if (proposal.cancelled) revert ProposalWasCancelled();

        proposal.cancelled = true;

        emit ProposalCancelled(operationId, operation);
    }

    /**
     * @notice Get proposal status
     * @param operationId The unique proposal ID
     * @return exists Whether proposal exists
     * @return executableAt When proposal can be executed
     * @return executed Whether proposal has been executed
     * @return cancelled Whether proposal was cancelled
     * @return expired Whether proposal has expired
     */
    function getProposalStatus(bytes32 operationId)
        external
        view
        returns (
            bool exists,
            uint256 executableAt,
            bool executed,
            bool cancelled,
            bool expired
        )
    {
        TimelockProposal storage proposal = proposals[operationId];
        exists = proposal.executableAt != 0;
        executableAt = proposal.executableAt;
        executed = proposal.executed;
        cancelled = proposal.cancelled;
        expired = exists && !executed && !cancelled &&
                  block.timestamp > proposal.executableAt + PROPOSAL_EXPIRY;
    }

    /**
     * @notice Get time remaining until proposal can be executed
     * @param operationId The unique proposal ID
     * @return timeRemaining Seconds until executable (0 if already executable or doesn't exist)
     */
    function getTimeUntilExecutable(bytes32 operationId) external view returns (uint256 timeRemaining) {
        TimelockProposal storage proposal = proposals[operationId];
        if (proposal.executableAt == 0 || block.timestamp >= proposal.executableAt) {
            return 0;
        }
        return proposal.executableAt - block.timestamp;
    }
}
