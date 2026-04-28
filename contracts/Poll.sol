// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "./interfaces/IVeriffAttester.sol";

/**
 * @title Poll
 * @notice Individual poll contract with instant USDC rewards for verified voters
 * @dev Deployed by PollFactory, votes are immutable once cast
 * @custom:security-contact security@truthpoll.com
 */
contract Poll is ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;

    /// @notice USDC token contract (Polygon Native: 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359)
    IERC20 public immutable usdc;

    /// @notice VeriffAttester contract for checking user verification
    IVeriffAttester public immutable veriffAttester;

    /// @notice Address that deployed this poll (PollFactory)
    address public immutable factory;

    /// @notice Address of poll creator
    address public immutable creator;

    /// @notice Trusted relayer address that can submit votes
    address public immutable trustedRelayer;

    /// @notice Treasury address for private vote rewards
    address public immutable treasury;

    /// @notice Poll question
    string public question;

    /// @notice Poll choices
    string[] public choices;

    /// @notice Maximum number of votes allowed
    uint256 public immutable maxVotes;

    /// @notice USDC reward amount per vote (in USDC decimals: 6)
    uint256 public immutable rewardPerVote;

    /// @notice Timestamp when poll ends
    uint256 public immutable endTime;

    /// @notice Total votes cast so far
    uint256 public totalVotes;

    /// @notice Whether poll was ended early by creator
    bool public endedEarly;

    /// @notice Whether unused rewards have been claimed
    bool public rewardsClaimed;

    /// @notice Mapping to track if address has voted
    mapping(address => bool) public hasVoted;

    /// @notice Vote counts for each option
    mapping(uint256 => uint256) public voteCounts;

    /// @notice EIP-712 domain separator for signature verification
    bytes32 public immutable DOMAIN_SEPARATOR;

    /// @notice EIP-712 typehash for vote signatures
    bytes32 public constant VOTE_TYPEHASH = keccak256(
        "Vote(address voter,uint256 choiceId,uint256 nonce,uint256 deadline)"
    );

    /// @notice Nonces for replay protection (per voter)
    mapping(address => uint256) public nonces;

    /// @notice Nonces for replay protection (per creator for gasless ending)
    mapping(address => uint256) public creatorNonces;

    /// @notice Mapping to track nullifiers for private votes
    mapping(bytes32 => bool) public nullifierUsed;

    /// @notice EIP-712 typehash for private vote signatures
    bytes32 public constant PRIVATE_VOTE_TYPEHASH = keccak256(
        "PrivateVote(bytes32 nullifier,uint256 choiceId,uint256 deadline)"
    );

    /// @notice EIP-712 typehash for gasless poll ending signatures
    bytes32 public constant END_POLL_TYPEHASH = keccak256(
        "EndPollEarly(address creator,uint256 nonce,uint256 deadline)"
    );

    /// @notice Emitted when a vote is cast
    event Voted(
        address indexed voter,
        uint256 indexed choiceId,
        uint256 reward
    );

    /// @notice Emitted when poll is ended early
    event PollEndedEarly(uint256 totalVotes, uint256 refundAmount);

    /// @notice Emitted when unused rewards are claimed
    event RewardsClaimed(address indexed creator, uint256 amount);

    /// @notice Emitted when a private vote is cast
    event PrivateVoted(
        bytes32 indexed nullifier,
        uint256 indexed choiceId,
        uint256 timestamp
    );

    /// @notice Thrown when user has already voted
    error AlreadyVoted();

    /// @notice Thrown when poll has ended
    error PollEnded();

    /// @notice Thrown when max votes reached
    error MaxVotesReached();

    /// @notice Thrown when invalid choice selected
    error InvalidChoice();

    /// @notice Thrown when user is not verified or has been revoked
    error NotVerifiedOrRevoked();

    /// @notice Thrown when only creator can call function
    error OnlyCreator();

    /// @notice Thrown when creator tries to vote on their own poll
    error CreatorCannotVote();

    /// @notice Thrown when poll has not ended yet
    error PollNotEnded();

    /// @notice Thrown when rewards have already been claimed
    error RewardsAlreadyClaimed();

    /// @notice Thrown when caller is not authorized to claim rewards
    error NotAuthorizedToClaim();

    /// @notice Thrown when signature has expired
    error SignatureExpired();

    /// @notice Thrown when signature is invalid
    error InvalidSignature();

    /// @notice Thrown when caller is not the trusted relayer
    error OnlyRelayer();

    /// @notice Thrown when nullifier has already been used
    error NullifierAlreadyUsed();

    /**
     * @notice Initialize poll contract
     * @param _creator Address of poll creator
     * @param _question Poll question
     * @param _choices Array of poll choices
     * @param _maxVotes Maximum number of votes
     * @param _rewardPerVote USDC reward per vote (6 decimals)
     * @param _endTime Timestamp when poll ends
     * @param _usdc USDC token address
     * @param _veriffAttester VeriffAttester contract address
     * @param _trustedRelayer Address of trusted relayer for gasless voting
     * @param _treasury Address to receive private vote rewards
     */
    constructor(
        address _creator,
        string memory _question,
        string[] memory _choices,
        uint256 _maxVotes,
        uint256 _rewardPerVote,
        uint256 _endTime,
        address _usdc,
        address _veriffAttester,
        address _trustedRelayer,
        address _treasury
    ) {
        require(_creator != address(0), "Invalid creator");
        require(bytes(_question).length > 0, "Empty question");
        require(_choices.length >= 2, "Min 2 choices");
        require(_choices.length <= 5, "Max 5 choices");
        require(_maxVotes > 0, "Max votes must be > 0");
        require(_endTime > block.timestamp, "End time must be future");
        require(_usdc != address(0), "Invalid USDC address");
        require(_veriffAttester != address(0), "Invalid attester address");
        require(_trustedRelayer != address(0), "Invalid relayer address");
        require(_treasury != address(0), "Invalid treasury address");

        factory = msg.sender;
        creator = _creator;
        question = _question;
        choices = _choices;
        maxVotes = _maxVotes;
        rewardPerVote = _rewardPerVote;
        endTime = _endTime;
        usdc = IERC20(_usdc);
        veriffAttester = IVeriffAttester(_veriffAttester);
        trustedRelayer = _trustedRelayer;
        treasury = _treasury;

        // Compute EIP-712 domain separator
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("Poll")),
                keccak256(bytes("1")),
                block.chainid,
                address(this)
            )
        );
    }

    /**
     * @notice Cast a vote using EIP-712 signature (gasless voting)
     * @dev Relayer submits transaction, voter signs off-chain
     * @dev Requires valid Veriff attestation (not revoked)
     * @dev Instantly transfers USDC reward to voter (not relayer)
     * @dev Vote is immutable once cast (cannot be changed)
     * @param voter Address of the voter (signer)
     * @param choiceId Index of choice to vote for
     * @param deadline Timestamp when signature expires
     * @param v Signature recovery value
     * @param r Signature r value
     * @param s Signature s value
     *
     * SECURITY: EIP-712 signature verification prevents unauthorized votes
     * SECURITY: Nonce prevents replay attacks
     * SECURITY: Deadline prevents stale signatures
     * SECURITY: Checks-Effects-Interactions pattern
     * SECURITY: ReentrancyGuard prevents reentrancy attacks
     * SECURITY: Attestation check ensures only KYC'd users can vote
     * SECURITY: Revoked users are blocked from voting
     */
    function voteWithSignature(
        address voter,
        uint256 choiceId,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant whenNotPaused {
        // SECURITY: Only trusted relayer can submit votes
        // This prevents users from bypassing eligibility checks by calling directly
        if (msg.sender != trustedRelayer) revert OnlyRelayer();

        // Check signature expiration
        if (block.timestamp > deadline) revert SignatureExpired();

        // Verify EIP-712 signature
        bytes32 structHash = keccak256(
            abi.encode(
                VOTE_TYPEHASH,
                voter,
                choiceId,
                nonces[voter],
                deadline
            )
        );
        bytes32 digest = MessageHashUtils.toTypedDataHash(DOMAIN_SEPARATOR, structHash);
        address signer = ECDSA.recover(digest, v, r, s);
        if (signer != voter) revert InvalidSignature();

        // Increment nonce to prevent replay
        nonces[voter]++;

        // Checks - same as original vote() but using voter parameter
        if (voter == creator) revert CreatorCannotVote();
        if (hasVoted[voter]) revert AlreadyVoted();
        if (block.timestamp >= endTime || endedEarly) revert PollEnded();
        if (totalVotes >= maxVotes) revert MaxVotesReached();
        if (choiceId >= choices.length) revert InvalidChoice();

        // CRITICAL: Verify VOTER has valid attestation (not relayer)
        if (!veriffAttester.isVerified(voter)) {
            revert NotVerifiedOrRevoked();
        }

        // Effects - Update state before external calls
        hasVoted[voter] = true;
        voteCounts[choiceId]++;
        totalVotes++;

        // Interactions - External calls last
        // IMPORTANT: Reward goes to voter, NOT msg.sender (relayer)
        if (rewardPerVote > 0) {
            usdc.safeTransfer(voter, rewardPerVote);
        }

        emit Voted(voter, choiceId, rewardPerVote);
    }

    /**
     * @notice Get nonce for a voter (for signature generation)
     * @param voter Address of voter
     * @return Current nonce for the voter
     */
    function getNonce(address voter) external view returns (uint256) {
        return nonces[voter];
    }

    /**
     * @notice Cast a private vote using nullifier (gasless, no reward to voter)
     * @dev Only trusted relayer can call. Nullifier derived from user's identityHash.
     * @dev No attestation check - backend verifies user has identityHash
     * @dev Reward goes to treasury instead of voter (privacy preservation)
     * @param nullifier keccak256(identityHash + pollAddress) - unique per human per poll
     * @param choiceId Index of choice to vote for
     * @param deadline Timestamp when signature expires
     * @param v Signature recovery value
     * @param r Signature r value
     * @param s Signature s value
     *
     * SECURITY: Only trusted relayer can submit private votes
     * SECURITY: Relayer signature proves backend authorized this nullifier
     * SECURITY: Nullifier prevents double voting by same identity
     * SECURITY: No wallet address stored on-chain (privacy)
     */
    function votePrivate(
        bytes32 nullifier,
        uint256 choiceId,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant whenNotPaused {
        // SECURITY: Only trusted relayer can submit private votes
        if (msg.sender != trustedRelayer) revert OnlyRelayer();

        // Check signature expiration
        if (block.timestamp > deadline) revert SignatureExpired();

        // Verify relayer signature (proves backend authorized this nullifier)
        bytes32 structHash = keccak256(
            abi.encode(
                PRIVATE_VOTE_TYPEHASH,
                nullifier,
                choiceId,
                deadline
            )
        );
        bytes32 digest = MessageHashUtils.toTypedDataHash(DOMAIN_SEPARATOR, structHash);
        address signer = ECDSA.recover(digest, v, r, s);
        if (signer != trustedRelayer) revert InvalidSignature();

        // Check poll state
        if (block.timestamp >= endTime || endedEarly) revert PollEnded();
        if (totalVotes >= maxVotes) revert MaxVotesReached();
        if (choiceId >= choices.length) revert InvalidChoice();
        if (nullifierUsed[nullifier]) revert NullifierAlreadyUsed();

        // Effects - Update state before external calls
        nullifierUsed[nullifier] = true;
        voteCounts[choiceId]++;
        totalVotes++;

        // Interactions - Send reward to treasury (not voter, for privacy)
        if (rewardPerVote > 0) {
            usdc.safeTransfer(treasury, rewardPerVote);
        }

        emit PrivateVoted(nullifier, choiceId, block.timestamp);
    }

    /**
     * @notice Check if a nullifier has been used
     * @param nullifier The nullifier to check
     * @return True if nullifier has been used
     */
    function isNullifierUsed(bytes32 nullifier) external view returns (bool) {
        return nullifierUsed[nullifier];
    }

    /**
     * @notice End poll early and refund unused rewards to creator
     * @dev Only creator can call this function
     * @dev Refunds (maxVotes - totalVotes) * rewardPerVote to creator
     *
     * SECURITY: ReentrancyGuard prevents reentrancy attacks
     * SECURITY: Only creator can reclaim unused rewards
     * SECURITY: Cannot withdraw rewards already distributed to voters
     */
    function endPollEarly() external nonReentrant {
        if (msg.sender != creator) revert OnlyCreator();
        if (block.timestamp >= endTime) revert PollEnded();
        if (endedEarly) revert PollEnded();

        endedEarly = true;
        rewardsClaimed = true;

        // Calculate refund: unused rewards only
        uint256 unusedVotes = maxVotes - totalVotes;
        uint256 refundAmount = unusedVotes * rewardPerVote;

        if (refundAmount > 0) {
            usdc.safeTransfer(creator, refundAmount);
        }

        emit PollEndedEarly(totalVotes, refundAmount);
    }

    /**
     * @notice End poll early using EIP-712 signature (gasless poll ending)
     * @dev Relayer submits transaction, creator signs off-chain
     * @dev Refunds (maxVotes - totalVotes) * rewardPerVote to creator
     * @param creatorAddr Address of the creator (signer) - must match poll creator
     * @param deadline Timestamp when signature expires
     * @param v Signature recovery value
     * @param r Signature r value
     * @param s Signature s value
     *
     * SECURITY: EIP-712 signature verification prevents unauthorized ending
     * SECURITY: Nonce prevents replay attacks
     * SECURITY: Deadline prevents stale signatures
     * SECURITY: Double authorization - signer must match creatorAddr AND creatorAddr must match creator
     * SECURITY: ReentrancyGuard prevents reentrancy attacks
     * SECURITY: Funds always sent to creator, not relayer
     */
    function endPollEarlyWithSignature(
        address creatorAddr,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant {
        // SECURITY: Only trusted relayer can submit gasless end poll requests
        if (msg.sender != trustedRelayer) revert OnlyRelayer();

        // Check signature expiration
        if (block.timestamp > deadline) revert SignatureExpired();

        // SECURITY: Creator address in signature must match poll creator
        if (creatorAddr != creator) revert OnlyCreator();

        // Verify EIP-712 signature
        bytes32 structHash = keccak256(
            abi.encode(
                END_POLL_TYPEHASH,
                creatorAddr,
                creatorNonces[creatorAddr],
                deadline
            )
        );
        bytes32 digest = MessageHashUtils.toTypedDataHash(DOMAIN_SEPARATOR, structHash);
        address signer = ECDSA.recover(digest, v, r, s);

        // SECURITY: Double check - signer must match provided creator address
        if (signer != creatorAddr) revert InvalidSignature();

        // Increment nonce to prevent replay
        creatorNonces[creatorAddr]++;

        // Check poll state
        if (block.timestamp >= endTime) revert PollEnded();
        if (endedEarly) revert PollEnded();

        // Effects - Update state before external calls
        endedEarly = true;
        rewardsClaimed = true;

        // Calculate refund: unused rewards only
        uint256 unusedVotes = maxVotes - totalVotes;
        uint256 refundAmount = unusedVotes * rewardPerVote;

        // Interactions - External calls last
        // IMPORTANT: Refund always goes to creator, NOT msg.sender (relayer)
        if (refundAmount > 0) {
            usdc.safeTransfer(creator, refundAmount);
        }

        emit PollEndedEarly(totalVotes, refundAmount);
    }

    /**
     * @notice Get nonce for a creator (for gasless end poll signature generation)
     * @param creatorAddr Address of creator
     * @return Current nonce for the creator
     */
    function getCreatorNonce(address creatorAddr) external view returns (uint256) {
        return creatorNonces[creatorAddr];
    }

    /**
     * @notice Check if this contract supports gasless poll ending
     * @dev Used for version detection - old polls won't have this function
     * @return True - this contract supports gasless poll ending
     */
    function supportsGaslessEndPoll() external pure returns (bool) {
        return true;
    }

    /**
     * @notice Claim unused rewards after poll ends naturally
     * @dev Only creator or factory can call. Funds always go to creator.
     * @dev Works after endTime passes or if endedEarly was called
     *
     * SECURITY: ReentrancyGuard prevents reentrancy attacks
     * SECURITY: Only creator or factory (for automated refunds) can trigger
     * SECURITY: Cannot claim if already claimed
     * SECURITY: Funds always sent to creator, not caller
     */
    function claimUnusedRewards() external nonReentrant {
        // Only creator or factory can trigger
        if (msg.sender != creator && msg.sender != factory) revert NotAuthorizedToClaim();

        // Poll must have ended (naturally or early)
        if (block.timestamp < endTime && !endedEarly) revert PollNotEnded();

        // Can only claim once
        if (rewardsClaimed) revert RewardsAlreadyClaimed();

        rewardsClaimed = true;

        // Calculate refund: unused rewards only
        uint256 unusedVotes = maxVotes - totalVotes;
        uint256 refundAmount = unusedVotes * rewardPerVote;

        if (refundAmount > 0) {
            usdc.safeTransfer(creator, refundAmount);
        }

        emit RewardsClaimed(creator, refundAmount);
    }

    /**
     * @notice Get current poll results
     * @return voteCounts_ Array of vote counts for each choice
     * @return totalVotes_ Total votes cast
     * @return ended Whether poll has ended
     */
    function getResults()
        external
        view
        returns (
            uint256[] memory voteCounts_,
            uint256 totalVotes_,
            bool ended
        )
    {
        voteCounts_ = new uint256[](choices.length);
        for (uint256 i = 0; i < choices.length; i++) {
            voteCounts_[i] = voteCounts[i];
        }
        totalVotes_ = totalVotes;
        ended = block.timestamp >= endTime || endedEarly;
    }

    /**
     * @notice Get all winning choices (handles ties)
     * @return winningChoiceIds Array of choice indices with highest votes
     * @return winningVotes Number of votes for winning choice(s)
     */
    function getWinners()
        external
        view
        returns (uint256[] memory winningChoiceIds, uint256 winningVotes)
    {
        // First pass: find max vote count
        uint256 maxVoteCount = 0;
        for (uint256 i = 0; i < choices.length; i++) {
            if (voteCounts[i] > maxVoteCount) {
                maxVoteCount = voteCounts[i];
            }
        }

        // Second pass: count how many choices have max votes
        uint256 winnerCount = 0;
        for (uint256 i = 0; i < choices.length; i++) {
            if (voteCounts[i] == maxVoteCount) {
                winnerCount++;
            }
        }

        // Third pass: collect winner IDs
        winningChoiceIds = new uint256[](winnerCount);
        uint256 index = 0;
        for (uint256 i = 0; i < choices.length; i++) {
            if (voteCounts[i] == maxVoteCount) {
                winningChoiceIds[index] = i;
                index++;
            }
        }

        return (winningChoiceIds, maxVoteCount);
    }

    /**
     * @notice Get single winning choice (most votes)
     * @dev Returns first choice in case of tie. Use getWinners() for tie handling.
     * @return winningChoiceId Index of choice with most votes
     * @return winningVotes Number of votes for winning choice
     */
    function getWinner()
        external
        view
        returns (uint256 winningChoiceId, uint256 winningVotes)
    {
        uint256 maxVoteCount = 0;
        uint256 winningChoice = 0;

        for (uint256 i = 0; i < choices.length; i++) {
            if (voteCounts[i] > maxVoteCount) {
                maxVoteCount = voteCounts[i];
                winningChoice = i;
            }
        }

        return (winningChoice, maxVoteCount);
    }

    /**
     * @notice Get all poll choices
     * @return Array of choice strings
     */
    function getChoices() external view returns (string[] memory) {
        return choices;
    }

    /**
     * @notice Emergency pause function (only factory can call)
     * @dev Prevents new votes while paused
     */
    function pause() external {
        require(msg.sender == factory, "Only factory");
        _pause();
    }

    /**
     * @notice Unpause function (only factory can call)
     */
    function unpause() external {
        require(msg.sender == factory, "Only factory");
        _unpause();
    }
}
