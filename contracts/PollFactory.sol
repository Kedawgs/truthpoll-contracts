// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "./Poll.sol";
import "./base/Timelocked.sol";

/**
 * @title PollFactory
 * @notice Factory contract for deploying Poll contracts with tiered fees
 * @dev Uses CREATE2 for deterministic addresses and gas efficiency
 * @custom:security-contact security@truthpoll.com
 */
contract PollFactory is ReentrancyGuard, Pausable, Ownable2Step, Timelocked {
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;

    /// @notice USDC token contract (Polygon Native: 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359)
    IERC20 public immutable usdc;

    /// @notice VeriffAttester contract address
    address public immutable veriffAttester;

    /// @notice Trusted relayer address for gasless voting
    address public trustedRelayer;

    /// @notice Treasury address where fees are sent
    address public treasury;

    /// @notice Address authorized to trigger batch refunds (relayer wallet)
    address public refunder;

    /// @notice Counter for poll IDs
    uint256 public pollCount;

    /// @notice Fixed poll duration: 30 days
    uint256 public constant POLL_DURATION = 30 days;

    /// @notice Mapping of poll ID to poll address
    mapping(uint256 => address) public polls;

    /// @notice Mapping to track polls created by this factory (for validation)
    mapping(address => bool) public isFactoryPoll;

    /// @notice Mapping of creator to their poll IDs
    mapping(address => uint256[]) public creatorPolls;

    /// @notice EIP-712 Domain Separator for signature verification
    bytes32 public immutable DOMAIN_SEPARATOR;

    /// @notice EIP-712 TypeHash for CreatePoll signature (endTime removed - fixed 30 day duration)
    bytes32 public constant CREATE_POLL_TYPEHASH = keccak256(
        "CreatePoll(address creator,bytes32 questionHash,bytes32 choicesHash,uint256 maxVotes,uint256 rewardPerVote,uint256 nonce,uint256 deadline)"
    );

    /// @notice Nonce mapping for replay protection
    mapping(address => uint256) public nonces;

    /// @notice Fee tier thresholds (votes)
    uint256 public constant TIER1_THRESHOLD = 10;
    uint256 public constant TIER2_THRESHOLD = 100;
    uint256 public constant TIER3_THRESHOLD = 1000;

    /// @notice Fee rates per vote (in USDC, 6 decimals)
    uint256 public constant TIER1_FEE = 0.10e6; // 0.10 USDC per vote
    uint256 public constant TIER2_FEE = 0.05e6; // 0.05 USDC per vote
    uint256 public constant TIER3_FEE = 0.02e6; // 0.02 USDC per vote
    uint256 public constant TIER4_FEE = 0.01e6; // 0.01 USDC per vote

    /// @notice Maximum votes per poll (sanity cap)
    uint256 public constant MAX_VOTES_CAP = 1_000_000;

    /// @notice Maximum reward per vote: 1000 USDC (matches frontend MAX_REWARD_PER_VOTE).
    ///         Prevents creator footguns like typing 1e18 (1T USDC) instead of 1e6 (1 USDC)
    ///         which would otherwise lock up the creator's USDC balance for the poll duration.
    uint256 public constant MAX_REWARD_PER_VOTE = 1000e6;

    /// @notice Maximum polls per batch refund (gas limit protection)
    uint256 public constant MAX_BATCH_SIZE = 200;

    /// @notice Operation identifiers for timelock
    string private constant OP_SET_TREASURY = "setTreasury";
    string private constant OP_SET_REFUNDER = "setRefunder";
    string private constant OP_SET_TRUSTED_RELAYER = "setTrustedRelayer";

    /// @notice Emitted when a new poll is created
    event PollCreated(
        address indexed poll,
        uint256 indexed pollId,
        address indexed creator,
        uint256 fee,
        uint256 rewardPool
    );

    /// @notice Emitted when treasury address is updated
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    /// @notice Emitted when refunder address is updated
    event RefunderUpdated(address indexed oldRefunder, address indexed newRefunder);

    /// @notice Emitted when trusted relayer address is updated
    event TrustedRelayerUpdated(address indexed oldRelayer, address indexed newRelayer);

    /// @notice Emitted when batch refund is processed for a poll
    event BatchRefundProcessed(address indexed poll, bool success);

    /// @notice Thrown when poll parameters are invalid
    error InvalidPollParameters();

    /// @notice Thrown when USDC transfer fails
    error TransferFailed();

    /// @notice Thrown when signature is invalid or signer is zero address
    error InvalidSignature();

    /// @notice Thrown when renounceOwnership is called (intentionally disabled)
    error RenounceDisabled();

    /**
     * @notice Initialize factory contract
     * @param _usdc USDC token address
     * @param _veriffAttester VeriffAttester contract address
     * @param _treasury Treasury address for fee collection
     * @param _trustedRelayer Trusted relayer address for gasless voting
     */
    constructor(
        address _usdc,
        address _veriffAttester,
        address _treasury,
        address _trustedRelayer
    ) Ownable(msg.sender) {
        require(_usdc != address(0), "Invalid USDC address");
        require(_veriffAttester != address(0), "Invalid attester address");
        require(_treasury != address(0), "Invalid treasury address");
        require(_trustedRelayer != address(0), "Invalid relayer address");

        usdc = IERC20(_usdc);
        veriffAttester = _veriffAttester;
        treasury = _treasury;
        trustedRelayer = _trustedRelayer;
        refunder = _trustedRelayer;

        // Compute EIP-712 domain separator
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("PollFactory")),
                keccak256(bytes("1")),
                block.chainid,
                address(this)
            )
        );
    }

    /**
     * @notice Calculate fee based on max votes (progressive bracket pricing)
     * @param maxVotes Maximum number of votes for the poll
     * @return Total fee in USDC (6 decimals)
     *
     * Progressive fee brackets (like tax brackets):
     * - First 10 votes: 0.10 USDC per vote ($1.00 max)
     * - Next 90 votes (11-100): 0.05 USDC per vote ($4.50 max)
     * - Next 900 votes (101-1000): 0.02 USDC per vote ($18.00 max)
     * - Remaining votes (1001+): 0.01 USDC per vote
     *
     * Pre-calculated cumulative fees at tier boundaries:
     * - 10 votes: 10 × $0.10 = $1.00 (1_000_000)
     * - 100 votes: $1.00 + 90 × $0.05 = $5.50 (5_500_000)
     * - 1000 votes: $5.50 + 900 × $0.02 = $23.50 (23_500_000)
     *
     * Example: 500 votes = $1.00 + $4.50 + (400 × $0.02) = $13.50
     */
    function calculateFee(uint256 maxVotes) public pure returns (uint256) {
        // Pre-calculated cumulative fees at tier boundaries for gas efficiency
        uint256 TIER1_CUMULATIVE = 1_000_000;   // 10 × 0.10 USDC = $1.00
        uint256 TIER2_CUMULATIVE = 5_500_000;   // $1.00 + 90 × 0.05 USDC = $5.50
        uint256 TIER3_CUMULATIVE = 23_500_000;  // $5.50 + 900 × 0.02 USDC = $23.50

        if (maxVotes <= TIER1_THRESHOLD) {
            return maxVotes * TIER1_FEE;
        } else if (maxVotes <= TIER2_THRESHOLD) {
            return TIER1_CUMULATIVE + (maxVotes - TIER1_THRESHOLD) * TIER2_FEE;
        } else if (maxVotes <= TIER3_THRESHOLD) {
            return TIER2_CUMULATIVE + (maxVotes - TIER2_THRESHOLD) * TIER3_FEE;
        } else {
            return TIER3_CUMULATIVE + (maxVotes - TIER3_THRESHOLD) * TIER4_FEE;
        }
    }

    /**
     * @notice Create a new poll with EIP-712 signature (gasless for user)
     * @dev Relayer submits transaction and pays gas, user only signs message
     * @dev Collects fee + reward pool in single USDC transfer from creator
     * @dev Deploys Poll contract using CREATE2 for gas efficiency
     * @dev All polls have a fixed 30-day duration (POLL_DURATION)
     * @param creator Address of the poll creator (not msg.sender/relayer)
     * @param question Poll question
     * @param choices Array of poll choices (2-5 choices)
     * @param maxVotes Maximum number of votes
     * @param rewardPerVote USDC reward per vote (6 decimals, can be 0)
     * @param deadline Signature expiration timestamp
     * @param v ECDSA signature component
     * @param r ECDSA signature component
     * @param s ECDSA signature component
     * @return pollAddress Address of deployed Poll contract
     *
     * SECURITY: EIP-712 signature verification prevents unauthorized poll creation
     * SECURITY: Nonce prevents replay attacks
     * SECURITY: Deadline prevents stale signatures
     * SECURITY: ReentrancyGuard prevents reentrancy attacks
     * SECURITY: Pausable allows emergency stop
     * SECURITY: Fee sent to treasury, rewards sent to Poll
     */
    function createPoll(
        address creator,
        string calldata question,
        string[] calldata choices,
        uint256 maxVotes,
        uint256 rewardPerVote,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant whenNotPaused returns (address pollAddress) {
        // Validate deadline
        require(block.timestamp <= deadline, "Signature expired");

        // Validate parameters
        if (bytes(question).length == 0) revert InvalidPollParameters();
        if (choices.length < 2 || choices.length > 5) revert InvalidPollParameters();
        if (maxVotes == 0 || maxVotes > MAX_VOTES_CAP) revert InvalidPollParameters();
        if (rewardPerVote > MAX_REWARD_PER_VOTE) revert InvalidPollParameters();

        // Calculate fixed endTime (30 days from now)
        uint256 endTime = block.timestamp + POLL_DURATION;

        // Calculate fee and reward pool
        uint256 fee = calculateFee(maxVotes);
        uint256 rewardPool = rewardPerVote * maxVotes;
        uint256 totalAmount = fee + rewardPool;

        // Hash question and choices for signature verification
        bytes32 questionHash = keccak256(bytes(question));
        bytes32 choicesHash = keccak256(abi.encode(choices));

        // Verify EIP-712 signature (endTime not included - fixed duration)
        bytes32 structHash = keccak256(
            abi.encode(
                CREATE_POLL_TYPEHASH,
                creator,
                questionHash,
                choicesHash,
                maxVotes,
                rewardPerVote,
                nonces[creator],
                deadline
            )
        );

        bytes32 digest = MessageHashUtils.toTypedDataHash(DOMAIN_SEPARATOR, structHash);
        address signer = ECDSA.recover(digest, v, r, s);
        if (signer != creator) revert InvalidSignature();

        // Increment nonce to prevent replay attacks
        nonces[creator]++;

        // Transfer USDC from creator (NOT from msg.sender/relayer)
        if (totalAmount > 0) {
            usdc.safeTransferFrom(creator, address(this), totalAmount);
        }

        // Deploy Poll contract using CREATE2
        bytes32 salt = keccak256(abi.encodePacked(creator, pollCount, block.timestamp));
        Poll poll = new Poll{salt: salt}(
            creator,
            question,
            choices,
            maxVotes,
            rewardPerVote,
            endTime,
            address(usdc),
            veriffAttester,
            trustedRelayer,
            treasury
        );

        pollAddress = address(poll);

        // Transfer fee to treasury
        if (fee > 0) {
            usdc.safeTransfer(treasury, fee);
        }

        // Transfer reward pool to Poll contract
        if (rewardPool > 0) {
            usdc.safeTransfer(pollAddress, rewardPool);
        }

        // Record poll (use creator, not msg.sender)
        uint256 pollId = pollCount;
        polls[pollId] = pollAddress;
        isFactoryPoll[pollAddress] = true;
        creatorPolls[creator].push(pollId);
        pollCount++;

        emit PollCreated(pollAddress, pollId, creator, fee, rewardPool);

        return pollAddress;
    }

    /**
     * @notice Get poll address by ID
     * @param pollId Poll ID
     * @return Poll contract address
     */
    function getPollAddress(uint256 pollId) external view returns (address) {
        return polls[pollId];
    }

    /**
     * @notice Get all poll IDs created by an address
     * @param creator Creator address
     * @return Array of poll IDs
     */
    function getCreatorPolls(address creator) external view returns (uint256[] memory) {
        return creatorPolls[creator];
    }

    // ========== TIMELOCKED ADMIN FUNCTIONS ==========

    /**
     * @notice Propose a new treasury address (starts 24-hour timelock)
     * @dev Only owner can call. Execute after TIMELOCK_DELAY (24 hours).
     * @param newTreasury New treasury address
     */
    function proposeTreasury(address newTreasury) external onlyOwner {
        require(newTreasury != address(0), "Invalid treasury address");
        _propose(OP_SET_TREASURY, newTreasury);
    }

    /**
     * @notice Execute treasury update after timelock (24 hours)
     * @param newTreasury The treasury address that was proposed
     */
    function executeTreasury(address newTreasury) external onlyOwner {
        _validateProposal(OP_SET_TREASURY, newTreasury);

        address oldTreasury = treasury;
        treasury = newTreasury;

        _markExecuted(OP_SET_TREASURY, newTreasury);
        emit TreasuryUpdated(oldTreasury, newTreasury);
    }

    /**
     * @notice Cancel a pending treasury proposal
     * @param newTreasury The treasury address that was proposed
     */
    function cancelTreasuryProposal(address newTreasury) external onlyOwner {
        _cancel(OP_SET_TREASURY, newTreasury);
    }

    /**
     * @notice Propose a new refunder address (starts 24-hour timelock)
     * @dev Only owner can call. Can propose address(0) to disable refunder role.
     * @param newRefunder New refunder address
     */
    function proposeRefunder(address newRefunder) external onlyOwner {
        _propose(OP_SET_REFUNDER, newRefunder);
    }

    /**
     * @notice Execute refunder update after timelock (24 hours)
     * @param newRefunder The refunder address that was proposed
     */
    function executeRefunder(address newRefunder) external onlyOwner {
        _validateProposal(OP_SET_REFUNDER, newRefunder);

        address oldRefunder = refunder;
        refunder = newRefunder;

        _markExecuted(OP_SET_REFUNDER, newRefunder);
        emit RefunderUpdated(oldRefunder, newRefunder);
    }

    /**
     * @notice Cancel a pending refunder proposal
     * @param newRefunder The refunder address that was proposed
     */
    function cancelRefunderProposal(address newRefunder) external onlyOwner {
        _cancel(OP_SET_REFUNDER, newRefunder);
    }

    /**
     * @notice Propose a new trusted relayer address (starts 24-hour timelock)
     * @dev Only owner can call. Only affects NEW polls; existing polls keep their relayer.
     * @param newRelayer New trusted relayer address
     */
    function proposeTrustedRelayer(address newRelayer) external onlyOwner {
        require(newRelayer != address(0), "Invalid relayer address");
        _propose(OP_SET_TRUSTED_RELAYER, newRelayer);
    }

    /**
     * @notice Execute trusted relayer update after timelock (24 hours)
     * @param newRelayer The relayer address that was proposed
     */
    function executeTrustedRelayer(address newRelayer) external onlyOwner {
        _validateProposal(OP_SET_TRUSTED_RELAYER, newRelayer);

        address oldRelayer = trustedRelayer;
        trustedRelayer = newRelayer;

        _markExecuted(OP_SET_TRUSTED_RELAYER, newRelayer);
        emit TrustedRelayerUpdated(oldRelayer, newRelayer);
    }

    /**
     * @notice Cancel a pending trusted relayer proposal
     * @param newRelayer The relayer address that was proposed
     */
    function cancelTrustedRelayerProposal(address newRelayer) external onlyOwner {
        _cancel(OP_SET_TRUSTED_RELAYER, newRelayer);
    }

    /**
     * @notice Trigger refunds for multiple ended polls in batch
     * @dev Only owner or refunder can call. Useful for automated daily refunds.
     * @dev Silently skips polls that fail (already claimed, not ended, etc.)
     * @dev Limited to MAX_BATCH_SIZE polls per call for gas safety
     * @param pollAddresses Array of Poll contract addresses to process (max 200)
     *
     * SECURITY: Only authorized addresses can trigger
     * SECURITY: Uses try/catch to prevent single failure from blocking batch
     * SECURITY: Funds always go to poll creators, not caller
     * SECURITY: Bounded array prevents gas limit attacks
     */
    function batchClaimRefunds(address[] calldata pollAddresses) external {
        require(msg.sender == owner() || msg.sender == refunder, "Not authorized");
        require(pollAddresses.length <= MAX_BATCH_SIZE, "Batch too large");

        for (uint256 i = 0; i < pollAddresses.length; i++) {
            address pollAddr = pollAddresses[i];

            // Security: Skip non-factory polls to prevent arbitrary contract calls
            if (!isFactoryPoll[pollAddr]) {
                emit BatchRefundProcessed(pollAddr, false);
                continue;
            }

            // Try to claim, emit event with success/failure status
            try Poll(pollAddr).claimUnusedRewards() {
                emit BatchRefundProcessed(pollAddr, true);
            } catch {
                emit BatchRefundProcessed(pollAddr, false);
            }
        }
    }

    /**
     * @notice Renouncing ownership is permanently disabled
     * @dev Renounce would brick every timelocked admin path (treasury / refunder /
     *      relayer / attester rotation) AND disable pause/unpause forever, with no
     *      recovery. Override forces a revert so neither operator error nor a
     *      compromised owner key can permanently disable admin functions.
     */
    function renounceOwnership() public override {
        revert RenounceDisabled();
    }

    /**
     * @notice Emergency pause function
     * @dev Prevents new poll creation while paused
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause function
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Emergency pause specific poll
     * @param pollAddress Address of poll to pause
     */
    function pausePoll(address pollAddress) external onlyOwner {
        require(isFactoryPoll[pollAddress], "Not a factory poll");
        Poll(pollAddress).pause();
    }

    /**
     * @notice Unpause specific poll
     * @param pollAddress Address of poll to unpause
     */
    function unpausePoll(address pollAddress) external onlyOwner {
        require(isFactoryPoll[pollAddress], "Not a factory poll");
        Poll(pollAddress).unpause();
    }
}
