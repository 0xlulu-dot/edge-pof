// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IAgentIdentity} from "./interfaces/IAgentIdentity.sol";
import {IVerifier} from "./interfaces/IVerifier.sol";
import {IPoFEngine} from "./interfaces/IPoFEngine.sol";
import {FeeCollector} from "./FeeCollector.sol";

/// @title BountyBoard — real-world task track.
/// @notice Publisher escrows a reward (whitelisted ERC20: USDT or EDGE) + a 50 EDGE stake and
///  names a governance-whitelisted verifier template. Gated agents commit-reveal; the first
///  valid reveal wins. 48h dispute window: publisher may dispute ONLY on verifier malfunction,
///  resolved by the ARBITER (governance in MVP). On finalize: 5% protocol fee -> FeeCollector
///  (50% buyback / 40% treasury / 10% dev), 95% to the solver, stake back to the publisher.
///
///  Mining subsidy (anti-wash-mining): solver gets
///      subsidy = min(subsidyBps * reward * price, subsidyCap)   only if R(solver) >= 0.5
///  and the contract enforces subsidy < fee (both valued in EDGE at the same governance price):
///      subsidyBps < feeBps is a setter invariant, and every payout clamps subsidy to fee - 1.
///  So a self-dealing publisher+solver always loses at least (fee - subsidy) > 0 per bounty.
contract BountyBoard is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant ARBITER_ROLE = keccak256("ARBITER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;
    uint256 public constant PUBLISHER_STAKE = 50e18;
    uint256 public constant DISPUTE_WINDOW = 48 hours;
    uint256 public constant SUBSIDY_MIN_REP = 5e17; // R >= 0.5

    enum Status {
        None,
        Open,
        Solved,
        Disputed,
        Finalized,
        Cancelled,
        Refunded
    }

    struct Bounty {
        address publisher;
        address token;
        address verifier;
        uint64 deadline;
        Status status;
        address solver;
        uint64 solvedAt;
        uint256 reward;
        bytes params;
    }

    struct BCommit {
        bytes32 commitment;
        uint64 blockNumber;
    }

    IERC20 public immutable edge;
    IPoFEngine public immutable engine;
    FeeCollector public immutable feeCollector;
    IAgentIdentity public identityGate;
    bool public requirePublisherGate; // default false: anyone may publish

    uint256 public feeBps = 500; // 5%
    uint256 public subsidyBps = 400; // 4%
    uint256 public subsidyCap = 5_000e18; // EDGE
    uint256 public verifierGasLimit = 8_000_000;

    mapping(address => bool) public verifierAllowed;
    mapping(address => bool) public tokenAllowed;
    mapping(address => uint256) public edgePrice; // EDGE (wei) per 1e18 token units

    uint256 public bountyCount;
    mapping(uint256 => Bounty) public bounties;
    mapping(uint256 => mapping(address => BCommit)) public commits;
    mapping(uint256 => uint256) public pendingSubsidy; // when engine was paused at finalize

    event BountyPosted(uint256 indexed id, address indexed publisher, address token, uint256 reward, address verifier, uint64 deadline);
    event BountyCommitted(uint256 indexed id, address indexed solver);
    event BountySolved(uint256 indexed id, address indexed solver);
    event BountyDisputed(uint256 indexed id);
    event DisputeResolved(uint256 indexed id, bool verifierMalfunction);
    event BountyFinalized(uint256 indexed id, address solver, uint256 payout, uint256 fee, uint256 subsidy);
    event BountyCancelled(uint256 indexed id);

    error BadParam();
    error BadPhase();
    error NotAgent();

    constructor(IERC20 edge_, IPoFEngine engine_, FeeCollector fc, IAgentIdentity gate, address admin, address arbiter, address pauser) {
        edge = edge_;
        engine = engine_;
        feeCollector = fc;
        identityGate = gate;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GOVERNANCE_ROLE, admin);
        _grantRole(ARBITER_ROLE, arbiter);
        _grantRole(PAUSER_ROLE, pauser);
    }

    // ------------------------- publisher -------------------------
    function postBounty(address token, uint256 reward, address verifier, bytes calldata params, uint64 deadline)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 id)
    {
        if (requirePublisherGate && !identityGate.isAgent(msg.sender)) revert NotAgent();
        if (!tokenAllowed[token] || !verifierAllowed[verifier] || reward == 0 || deadline <= block.timestamp) {
            revert BadParam();
        }
        id = ++bountyCount;
        Bounty storage b = bounties[id];
        b.publisher = msg.sender;
        b.token = token;
        b.verifier = verifier;
        b.deadline = deadline;
        b.status = Status.Open;
        b.reward = reward;
        b.params = params;
        edge.safeTransferFrom(msg.sender, address(this), PUBLISHER_STAKE);
        IERC20(token).safeTransferFrom(msg.sender, address(this), reward);
        emit BountyPosted(id, msg.sender, token, reward, verifier, deadline);
    }

    /// @notice No solution by the deadline -> publisher recovers reward + stake. Never paused.
    function cancel(uint256 id) external nonReentrant {
        Bounty storage b = bounties[id];
        if (msg.sender != b.publisher || b.status != Status.Open || block.timestamp <= b.deadline) revert BadPhase();
        b.status = Status.Cancelled;
        IERC20(b.token).safeTransfer(b.publisher, b.reward);
        edge.safeTransfer(b.publisher, PUBLISHER_STAKE);
        emit BountyCancelled(id);
    }

    // ------------------------- solver -------------------------
    /// @notice commitment = keccak256(abi.encode(answer, salt, msg.sender))
    function commit(uint256 id, bytes32 commitment) external whenNotPaused {
        if (!identityGate.isAgent(msg.sender)) revert NotAgent();
        Bounty storage b = bounties[id];
        if (b.status != Status.Open || block.timestamp > b.deadline) revert BadPhase();
        commits[id][msg.sender] = BCommit(commitment, uint64(block.number));
        emit BountyCommitted(id, msg.sender);
    }

    /// @notice First valid reveal wins. The commit must be from an earlier block (anti front-run).
    function reveal(uint256 id, bytes calldata answer, bytes32 salt) external nonReentrant {
        Bounty storage b = bounties[id];
        if (b.status != Status.Open || block.timestamp > b.deadline) revert BadPhase();
        BCommit memory c = commits[id][msg.sender];
        if (c.commitment == bytes32(0) || c.blockNumber >= block.number) revert BadPhase();
        if (keccak256(abi.encode(answer, salt, msg.sender)) != c.commitment) revert BadParam();
        bool ok;
        try IVerifier(b.verifier).verify{gas: verifierGasLimit}(b.params, answer) returns (bool r) {
            ok = r;
        } catch {}
        if (!ok) revert BadParam();
        b.status = Status.Solved;
        b.solver = msg.sender;
        b.solvedAt = uint64(block.timestamp);
        emit BountySolved(id, msg.sender);
    }

    // ------------------------- dispute -------------------------
    /// @notice Publisher may only dispute on grounds of verifier malfunction (judged off-chain
    ///         by the arbiter in MVP).
    function dispute(uint256 id) external {
        Bounty storage b = bounties[id];
        if (msg.sender != b.publisher || b.status != Status.Solved) revert BadPhase();
        if (block.timestamp >= uint256(b.solvedAt) + DISPUTE_WINDOW) revert BadPhase();
        b.status = Status.Disputed;
        emit BountyDisputed(id);
    }

    function resolveDispute(uint256 id, bool verifierMalfunction) external onlyRole(ARBITER_ROLE) nonReentrant {
        Bounty storage b = bounties[id];
        if (b.status != Status.Disputed) revert BadPhase();
        emit DisputeResolved(id, verifierMalfunction);
        if (verifierMalfunction) {
            b.status = Status.Refunded;
            IERC20(b.token).safeTransfer(b.publisher, b.reward);
            edge.safeTransfer(b.publisher, PUBLISHER_STAKE);
        } else {
            // frivolous dispute: publisher stake goes to the treasury, solver is paid normally
            edge.safeTransfer(address(feeCollector), PUBLISHER_STAKE);
            feeCollector.notifyTreasury(address(edge), PUBLISHER_STAKE);
            _payout(id, b, false);
        }
    }

    /// @notice After the dispute window. Never paused (escrow release).
    function finalize(uint256 id) external nonReentrant {
        Bounty storage b = bounties[id];
        if (b.status != Status.Solved || block.timestamp < uint256(b.solvedAt) + DISPUTE_WINDOW) revert BadPhase();
        _payout(id, b, true);
    }

    function _payout(uint256 id, Bounty storage b, bool returnStake) internal {
        b.status = Status.Finalized;
        uint256 fee = (b.reward * feeBps) / BPS;
        uint256 payout = b.reward - fee;
        IERC20(b.token).safeTransfer(b.solver, payout);
        if (fee > 0) {
            IERC20(b.token).safeTransfer(address(feeCollector), fee);
            feeCollector.notifyFee(b.token, fee);
        }
        if (returnStake) edge.safeTransfer(b.publisher, PUBLISHER_STAKE);

        uint256 sub = computeSubsidy(b.token, b.reward, engine.reputationOf(b.solver));
        if (sub > 0) {
            if (engine.paused()) {
                pendingSubsidy[id] = sub;
            } else {
                sub = engine.creditSubsidy(b.solver, sub);
            }
        }
        emit BountyFinalized(id, b.solver, payout, fee, sub);
    }

    /// @notice Credit a subsidy that was deferred because the engine was paused at finalize.
    function creditPendingSubsidy(uint256 id) external nonReentrant {
        uint256 sub = pendingSubsidy[id];
        if (sub == 0) revert BadPhase();
        pendingSubsidy[id] = 0;
        engine.creditSubsidy(bounties[id].solver, sub);
    }

    /// @notice Subsidy in EDGE. Always strictly less than the protocol fee valued in EDGE.
    function computeSubsidy(address token, uint256 reward, uint256 solverRep) public view returns (uint256 sub) {
        if (solverRep < SUBSIDY_MIN_REP) return 0;
        uint256 price = edgePrice[token];
        if (price == 0) return 0;
        uint256 feeEdge = (((reward * feeBps) / BPS) * price) / WAD;
        sub = (((reward * subsidyBps) / BPS) * price) / WAD;
        if (sub > subsidyCap) sub = subsidyCap;
        if (sub >= feeEdge) sub = feeEdge == 0 ? 0 : feeEdge - 1; // hard invariant: subsidy < fee
    }

    // ------------------------- governance -------------------------
    function setVerifier(address v, bool ok) external onlyRole(GOVERNANCE_ROLE) {
        verifierAllowed[v] = ok;
    }

    function setToken(address t, bool ok, uint256 priceInEdge) external onlyRole(GOVERNANCE_ROLE) {
        tokenAllowed[t] = ok;
        edgePrice[t] = priceInEdge;
    }

    function setFees(uint256 feeBps_, uint256 subsidyBps_, uint256 cap_) external onlyRole(GOVERNANCE_ROLE) {
        if (feeBps_ > 1_000 || subsidyBps_ >= feeBps_) revert BadParam(); // subsidy < fee
        feeBps = feeBps_;
        subsidyBps = subsidyBps_;
        subsidyCap = cap_;
    }

    function setIdentityGate(address g, bool requireForPublisher) external onlyRole(GOVERNANCE_ROLE) {
        if (g == address(0)) revert BadParam();
        identityGate = IAgentIdentity(g);
        requirePublisherGate = requireForPublisher;
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }
}
