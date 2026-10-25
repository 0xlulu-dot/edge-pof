// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {EDGEToken} from "./EDGEToken.sol";
import {PoFMath} from "./PoFMath.sol";
import {IAgentIdentity} from "./interfaces/IAgentIdentity.sol";
import {IVerifier} from "./interfaces/IVerifier.sol";
import {IRandomness} from "./interfaces/IRandomness.sol";
import {IPoFEngine} from "./interfaces/IPoFEngine.sol";

/// @title PoFEngine — Proof of Frontier mining engine (the only EDGE mining Minter)
/// @notice Rounds of N difficulty rungs. An off-chain generator (later: TEE) commits to puzzles
///         (hash of params+salt), AI agents (IdentityGate) commit answers with a 10 EDGE bond,
///         the generator reveals the puzzle, agents reveal answers, pluggable verifiers check
///         them, and the round's emission is split with a crowding factor g(n_eff).
///
/// Roles (production wiring, see script/Deploy.s.sol):
///   DEFAULT_ADMIN_ROLE, GOVERNANCE_ROLE, ORACLE_ROLE -> TimelockController (7 days)
///   GENERATOR_ROLE -> puzzle operator (later a TEE-attested key)
///   PAUSER_ROLE    -> guardian; pause only stops NEW rounds/commits/settlements/subsidies.
///                     reveal (bond return), refundBond, accrue and claim are never paused.
contract PoFEngine is IPoFEngine, AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using PoFMath for uint256;

    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");
    bytes32 public constant GENERATOR_ROLE = keccak256("GENERATOR_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;

    // ---------------- emission constants ----------------
    uint256 public constant INITIAL_DAILY_EMISSION = 92_000e18;
    uint256 public constant BASE_DAILY_DECAY = 1e15; // 0.1% per day
    uint256 public constant MIN_INDEX_MULT = 7e17; // 0.7
    uint256 public constant MAX_INDEX_MULT = 13e17; // 1.3

    // ---------------- reputation constants ----------------
    uint256 public constant R_MIN = 1e17; // 0.1
    uint256 public constant R_MAX = 1e18; // 1.0
    uint256 public constant R_UP = 5e16; // +0.05
    uint256 public constant R_DOWN = 1e17; // -0.1
    uint256 public constant R_DAILY_KEEP = 99e16; // excess over R_MIN decays 1%/day inactive

    uint256 public constant BOND = 10e18;
    uint256 public constant MAX_RUNGS = 10;
    uint256 public constant SOLVER_SHARE_BPS = 8_000; // 80% solvers / 20% forecasters

    EDGEToken public immutable token;
    uint256 public immutable genesis;
    uint256 public immutable miningCap;

    // ---------------- governance params ----------------
    IAgentIdentity public identityGate;
    IRandomness public randomness;
    address public forecastMarket;
    address public bountyBoard;
    bool public forecastEnabled;
    uint256 public indexMultiplier = WAD;
    uint64 public roundDuration = 4 hours; // cold start; governance moves to 1h later
    uint8 public numRungs = 5;
    uint16 public forecastEndBps = 1_000; // forecasts only before this point (and before puzzles)
    uint16 public commitEndBps = 6_000;
    uint16 public genRevealEndBps = 7_000;
    uint256 public verifierGasLimit = 8_000_000;
    mapping(address => bool) public verifierAllowed;

    // ---------------- emission state ----------------
    uint256 public checkpointDay;
    uint256 public checkpointDaily = INITIAL_DAILY_EMISSION;
    uint256 public emissionAllocated; // fresh emission ever assigned (rounds + subsidies), <= miningCap
    uint256 public totalBurnedUnminted; // allocated but never minted ("burned" by the protocol)
    uint256 public totalBondsBurned; // real EDGE burned from bonds
    uint256 public rolloverPool; // waits for the next round
    uint256 public totalAccrued; // credited to users (pending + claimed)
    uint256 public totalClaimed;
    uint256 public sweetSpot = 1 << 16; // difficulty units, generator-interpreted

    // ---------------- rounds ----------------
    struct Round {
        uint64 start;
        uint64 duration;
        uint64 settledAt;
        uint8 numRungs;
        bool puzzlesPosted;
        bool settled;
        uint32 activeIDs;
        uint256 pool; // emission + rollover
        uint256 freshEmission;
        uint256 seed;
    }

    struct Rung {
        bytes32 puzzleHash;
        address verifier;
        uint256 difficulty;
        bool revealed;
        uint8 bucket;
        uint32 distinct;
        uint256 sumR; // n_eff (WAD)
        uint256 payout;
        uint256 bondsOutstanding;
    }

    struct Commit {
        bytes32 commitment;
        bool revealed;
        bool correct;
        bool distinct;
        bool accrued;
        bool refunded;
        uint64 r; // reputation snapshot at reveal (WAD; fits in uint64)
    }

    struct Rep {
        uint64 r;
        uint32 lastDay;
        bool init;
    }

    uint256 public roundCount;
    mapping(uint256 => Round) public rounds;
    mapping(uint256 => mapping(uint8 => Rung)) public rungs;
    mapping(uint256 => mapping(uint8 => string)) public puzzleURI;
    mapping(uint256 => mapping(uint8 => bytes)) public puzzleParams;
    mapping(uint256 => mapping(uint8 => mapping(address => Commit))) public commits;
    mapping(uint256 => mapping(uint8 => mapping(bytes32 => address))) public firstRevealer;
    mapping(uint256 => mapping(address => bool)) public activeIn;
    mapping(address => Rep) internal _rep;
    mapping(address => uint256) public pendingRewards;

    mapping(uint256 => uint256) public forecastBudget;
    mapping(uint256 => uint256) public forecastPaid;
    mapping(uint256 => bool) public forecastReturned;

    // ---------------- errors / events ----------------
    error NotAgent();
    error BadPhase();
    error BadParam();
    error AlreadyDone();
    error NotAllowed();

    event RoundStarted(uint256 indexed roundId, uint256 pool, uint256 freshEmission, uint8 numRungs, uint64 start);
    event PuzzlePosted(uint256 indexed roundId, uint8 rung, bytes32 puzzleHash, address verifier, uint256 difficulty, string uri);
    event PuzzleRevealed(uint256 indexed roundId, uint8 rung, bytes params);
    event Committed(uint256 indexed roundId, uint8 rung, address indexed agent);
    event Revealed(uint256 indexed roundId, uint8 rung, address indexed agent, bool correct, bool distinct);
    event BondBurned(address indexed agent, uint256 amount);
    event RoundSettled(uint256 indexed roundId, uint256 paid, uint256 burnedUnminted, uint256 rolledOver, uint256 forecastBudget);
    event Accrued(address indexed user, uint256 amount);
    event Claimed(address indexed user, uint256 amount);
    event ParamChanged(bytes32 indexed what, uint256 value);
    event AddressChanged(bytes32 indexed what, address value);

    constructor(EDGEToken token_, IAgentIdentity gate_, IRandomness rnd_, address admin, address generator, address pauser) {
        token = token_;
        miningCap = token_.MINING_CAP();
        identityGate = gate_;
        randomness = rnd_;
        genesis = block.timestamp;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GOVERNANCE_ROLE, admin);
        _grantRole(ORACLE_ROLE, admin);
        _grantRole(GENERATOR_ROLE, generator);
        _grantRole(PAUSER_ROLE, pauser);
    }

    // =====================================================================
    //                              EMISSION
    // =====================================================================

    function currentDay() public view returns (uint256) {
        return (block.timestamp - genesis) / 1 days;
    }

    /// @notice daily decay factor = 1 - 0.1% * indexMultiplier
    function dailyFactor() public view returns (uint256) {
        return WAD - (BASE_DAILY_DECAY * indexMultiplier) / WAD;
    }

    function dailyEmissionAt(uint256 day) public view returns (uint256) {
        if (day < checkpointDay) day = checkpointDay;
        return (checkpointDaily * PoFMath.rpow(dailyFactor(), day - checkpointDay)) / WAD;
    }

    function roundEmissionNow(uint64 duration) public view returns (uint256 e) {
        e = (dailyEmissionAt(currentDay()) * duration) / 1 days;
        uint256 left = miningCap - emissionAllocated;
        if (e > left) e = left;
    }

    // =====================================================================
    //                              ROUNDS
    // =====================================================================

    /// @notice Anyone (keeper) may open the next round once the previous one's window ended.
    function startRound() external whenNotPaused returns (uint256 id) {
        if (roundCount > 0) {
            Round storage prev = rounds[roundCount];
            if (block.timestamp < prev.start + prev.duration) revert BadPhase();
        }
        id = ++roundCount;
        uint64 dur = roundDuration;
        uint256 fresh = roundEmissionNow(dur);
        emissionAllocated += fresh;
        uint256 pool = fresh + rolloverPool;
        rolloverPool = 0;

        Round storage r = rounds[id];
        r.start = uint64(block.timestamp);
        r.duration = dur;
        r.numRungs = numRungs;
        r.pool = pool;
        r.freshEmission = fresh;

        // ladder centered on the previous sweet spot, difficulty doubles per rung
        uint8 n = numRungs;
        uint256 mid = n / 2;
        for (uint8 i = 0; i < n; i++) {
            uint256 d = i >= mid ? sweetSpot << (i - mid) : sweetSpot >> (mid - i);
            rungs[id][i].difficulty = d == 0 ? 1 : d;
        }
        randomness.requestSeed(id);
        emit RoundStarted(id, pool, fresh, n, r.start);
    }

    function _phaseTime(Round storage r, uint16 bps) internal view returns (uint256) {
        return uint256(r.start) + (uint256(r.duration) * bps) / BPS;
    }

    function forecastEndOf(uint256 id) public view returns (uint256) {
        return _phaseTime(rounds[id], forecastEndBps);
    }

    function commitEndOf(uint256 id) public view returns (uint256) {
        return _phaseTime(rounds[id], commitEndBps);
    }

    function genRevealEndOf(uint256 id) public view returns (uint256) {
        return _phaseTime(rounds[id], genRevealEndBps);
    }

    function roundEndOf(uint256 id) public view returns (uint256) {
        Round storage r = rounds[id];
        return uint256(r.start) + r.duration;
    }

    /// @notice Generator posts puzzle commitments: puzzleHash = keccak256(abi.encode(params, salt)).
    function postPuzzles(uint256 id, bytes32[] calldata hashes, address[] calldata verifiers, string[] calldata uris)
        external
        onlyRole(GENERATOR_ROLE)
        whenNotPaused
    {
        Round storage r = rounds[id];
        if (r.start == 0 || r.puzzlesPosted) revert BadPhase();
        if (forecastEnabled && block.timestamp < forecastEndOf(id)) revert BadPhase();
        if (block.timestamp >= commitEndOf(id)) revert BadPhase();
        uint8 n = r.numRungs;
        if (hashes.length != n || verifiers.length != n || uris.length != n) revert BadParam();
        (bool ready, uint256 seed) = randomness.seedOf(id);
        if (!ready) revert BadPhase();
        r.seed = seed;
        r.puzzlesPosted = true;
        for (uint8 i = 0; i < n; i++) {
            if (!verifierAllowed[verifiers[i]] || hashes[i] == bytes32(0)) revert BadParam();
            Rung storage g = rungs[id][i];
            g.puzzleHash = hashes[i];
            g.verifier = verifiers[i];
            puzzleURI[id][i] = uris[i];
            emit PuzzlePosted(id, i, hashes[i], verifiers[i], g.difficulty, uris[i]);
        }
    }

    /// @notice commitment = keccak256(abi.encode(answer, salt, msg.sender)); posts a 10 EDGE bond.
    function commit(uint256 id, uint8 rung, bytes32 commitment) external nonReentrant whenNotPaused {
        if (!identityGate.isAgent(msg.sender)) revert NotAgent();
        Round storage r = rounds[id];
        if (!r.puzzlesPosted || block.timestamp >= commitEndOf(id) || rung >= r.numRungs) revert BadPhase();
        Commit storage c = commits[id][rung][msg.sender];
        if (c.commitment != bytes32(0)) revert AlreadyDone();
        if (commitment == bytes32(0)) revert BadParam();
        c.commitment = commitment;
        rungs[id][rung].bondsOutstanding += BOND;
        if (!activeIn[id][msg.sender]) {
            activeIn[id][msg.sender] = true;
            r.activeIDs++;
        }
        IERC20(address(token)).safeTransferFrom(msg.sender, address(this), BOND);
        emit Committed(id, rung, msg.sender);
    }

    /// @notice Generator opens the puzzle after the commit window.
    function revealPuzzle(uint256 id, uint8 rung, bytes calldata params, bytes32 salt) external {
        Round storage r = rounds[id];
        if (!r.puzzlesPosted || rung >= r.numRungs) revert BadPhase();
        if (block.timestamp < commitEndOf(id) || block.timestamp >= genRevealEndOf(id)) revert BadPhase();
        Rung storage g = rungs[id][rung];
        if (g.revealed) revert AlreadyDone();
        if (keccak256(abi.encode(params, salt)) != g.puzzleHash) revert BadParam();
        // anyone holding (params, salt) may reveal: the hash binds it, the generator cannot lie.
        g.revealed = true;
        puzzleParams[id][rung] = params;
        emit PuzzleRevealed(id, rung, params);
    }

    /// @notice Solver reveal. Never paused (it is how bonds come back).
    function revealAnswer(uint256 id, uint8 rung, bytes calldata answer, bytes32 salt) external nonReentrant {
        Rung storage g = rungs[id][rung];
        if (!g.revealed || block.timestamp >= roundEndOf(id)) revert BadPhase();
        Commit storage c = commits[id][rung][msg.sender];
        if (c.commitment == bytes32(0) || c.revealed) revert AlreadyDone();
        if (keccak256(abi.encode(answer, salt, msg.sender)) != c.commitment) revert BadParam();
        c.revealed = true;
        g.bondsOutstanding -= BOND;

        bool ok = _verify(g.verifier, puzzleParams[id][rung], answer);
        uint256 rNow = reputationOf(msg.sender);
        if (ok) {
            c.correct = true;
            bytes32 ah = keccak256(answer);
            if (firstRevealer[id][rung][ah] == address(0)) {
                // distinct solution: counts toward n_eff and earns the rung share
                firstRevealer[id][rung][ah] = msg.sender;
                c.distinct = true;
                c.r = uint64(rNow);
                g.sumR += rNow;
                g.distinct++;
                _setRep(msg.sender, rNow + R_UP);
            } else {
                // duplicate of an already-revealed answer: bond back, no reward, no reputation gain
                _setRep(msg.sender, rNow);
            }
            IERC20(address(token)).safeTransfer(msg.sender, BOND);
        } else {
            _setRep(msg.sender, rNow > R_DOWN + R_MIN ? rNow - R_DOWN : R_MIN);
            totalBondsBurned += BOND;
            token.burn(BOND);
            emit BondBurned(msg.sender, BOND);
        }
        emit Revealed(id, rung, msg.sender, ok, c.distinct);
    }

    /// @notice If the generator never revealed a rung, committers get their bond back. Never paused.
    function refundBond(uint256 id, uint8 rung) external nonReentrant {
        Rung storage g = rungs[id][rung];
        if (g.revealed || block.timestamp < genRevealEndOf(id)) revert BadPhase();
        Commit storage c = commits[id][rung][msg.sender];
        if (c.commitment == bytes32(0) || c.refunded || c.revealed) revert AlreadyDone();
        c.refunded = true;
        g.bondsOutstanding -= BOND;
        IERC20(address(token)).safeTransfer(msg.sender, BOND);
    }

    function _verify(address v, bytes memory params, bytes calldata answer) internal returns (bool) {
        try IVerifier(v).verify{gas: verifierGasLimit}(params, answer) returns (bool ok) {
            return ok;
        } catch {
            return false;
        }
    }

    // =====================================================================
    //                              SETTLEMENT
    // =====================================================================

    function settle(uint256 id) external nonReentrant whenNotPaused {
        Round storage r = rounds[id];
        if (r.start == 0 || r.settled || block.timestamp < roundEndOf(id)) revert BadPhase();
        r.settled = true;
        r.settledAt = uint64(block.timestamp);

        uint256 solverPool = (r.pool * SOLVER_SHARE_BPS) / BPS;
        uint256 forecastPool = r.pool - solverPool;
        uint256 k = PoFMath.kFor(r.activeIDs);
        uint8 n = r.numRungs;
        uint256 sumW = (uint256(1) << n) - 1; // sum of 2^r for r in [0, n)

        uint256 paid;
        uint256 unrevealedShare; // generator failure -> 100% rollover, no burn
        uint256 bondsToBurn;
        for (uint8 i = 0; i < n; i++) {
            Rung storage g = rungs[id][i];
            uint256 base = (solverPool * (uint256(1) << i)) / sumW;
            if (!g.revealed) {
                unrevealedShare += base;
                continue;
            }
            bondsToBurn += g.bondsOutstanding; // committed but never revealed
            g.bondsOutstanding = 0;
            g.bucket = PoFMath.bucket(g.sumR, k);
            uint256 share = (base * PoFMath.g(g.sumR, k)) / WAD;
            g.payout = share;
            paid += share;
        }
        uint256 unpaid = solverPool - paid - unrevealedShare;
        uint256 fb;
        if (forecastEnabled && forecastMarket != address(0) && r.puzzlesPosted) {
            fb = forecastPool;
            forecastBudget[id] = fb;
        } else {
            unpaid += forecastPool;
        }
        uint256 burnPart = unpaid / 2;
        totalBurnedUnminted += burnPart;
        uint256 rolled = unpaid - burnPart + unrevealedShare;
        rolloverPool += rolled;

        if (bondsToBurn > 0) {
            totalBondsBurned += bondsToBurn;
            token.burn(bondsToBurn);
        }
        _updateSweetSpot(id, n);
        emit RoundSettled(id, paid, burnPart, rolled, fb);
    }

    function _updateSweetSpot(uint256 id, uint8 n) internal {
        Rung storage top = rungs[id][n - 1];
        if (top.revealed && top.bucket == 3) {
            sweetSpot = top.difficulty * 2; // even the hardest rung is crowded: move up
            return;
        }
        int256 best2 = -1;
        int256 bestAny = -1;
        for (uint8 i = 0; i < n; i++) {
            Rung storage g = rungs[id][i];
            if (!g.revealed) continue;
            if (g.bucket == 2) best2 = int256(uint256(i));
            if (g.bucket >= 1) bestAny = int256(uint256(i));
        }
        if (best2 >= 0) sweetSpot = rungs[id][uint8(uint256(best2))].difficulty;
        else if (bestAny >= 0) sweetSpot = rungs[id][uint8(uint256(bestAny))].difficulty;
        else if (sweetSpot > 1) sweetSpot = sweetSpot / 2;
    }

    /// @notice Permissionless: move a distinct solver's rung share into their pending balance.
    function accrueSolver(uint256 id, uint8 rung, address user) public {
        if (!rounds[id].settled) revert BadPhase();
        Commit storage c = commits[id][rung][user];
        if (!c.distinct || c.accrued) revert AlreadyDone();
        c.accrued = true;
        Rung storage g = rungs[id][rung];
        uint256 amt = (g.payout * c.r) / g.sumR;
        _accrue(user, amt);
    }

    function claimable(uint256 id, uint8 rung, address user) external view returns (uint256) {
        Commit storage c = commits[id][rung][user];
        Rung storage g = rungs[id][rung];
        if (!rounds[id].settled || !c.distinct || c.accrued || g.sumR == 0) return 0;
        return (g.payout * c.r) / g.sumR;
    }

    /// @notice Mint all accrued rewards. Never paused (already-earned rewards).
    function claim() external nonReentrant returns (uint256 amt) {
        amt = pendingRewards[msg.sender];
        if (amt == 0) return 0;
        pendingRewards[msg.sender] = 0;
        totalClaimed += amt;
        token.mintMining(msg.sender, amt);
        emit Claimed(msg.sender, amt);
    }

    function _accrue(address user, uint256 amt) internal {
        if (amt == 0) return;
        pendingRewards[user] += amt;
        totalAccrued += amt;
        emit Accrued(user, amt);
    }

    // =====================================================================
    //                    FORECAST + BOUNTY HOOKS
    // =====================================================================

    function forecastView(uint256 id) external view returns (ForecastView memory v) {
        Round storage r = rounds[id];
        v = ForecastView({
            start: r.start,
            forecastEnd: uint64(forecastEndOf(id)),
            settledAt: r.settledAt,
            numRungs: r.numRungs,
            puzzlesPosted: r.puzzlesPosted,
            settled: r.settled
        });
    }

    function rungBucket(uint256 id, uint8 rung) external view returns (uint8) {
        return rungs[id][rung].bucket;
    }

    function creditForecast(uint256 id, address user, uint256 amount) external {
        if (msg.sender != forecastMarket || forecastReturned[id]) revert NotAllowed();
        if (forecastPaid[id] + amount > forecastBudget[id]) revert BadParam();
        forecastPaid[id] += amount;
        _accrue(user, amount);
    }

    /// @notice Unused forecast budget follows the standard unpaid rule: 50% burned, 50% rolled.
    function returnForecastUnused(uint256 id) external {
        if (msg.sender != forecastMarket || forecastReturned[id]) revert NotAllowed();
        forecastReturned[id] = true;
        uint256 unused = forecastBudget[id] - forecastPaid[id];
        uint256 burnPart = unused / 2;
        totalBurnedUnminted += burnPart;
        rolloverPool += unused - burnPart;
    }

    /// @notice Bounty mining subsidy (BountyBoard enforces subsidy < protocol fee). Counts as
    ///         fresh emission against the 92M mining cap.
    function creditSubsidy(address user, uint256 amount) external whenNotPaused returns (uint256 credited) {
        if (msg.sender != bountyBoard) revert NotAllowed();
        uint256 left = miningCap - emissionAllocated;
        credited = amount > left ? left : amount;
        emissionAllocated += credited;
        _accrue(user, credited);
    }

    // =====================================================================
    //                              REPUTATION
    // =====================================================================

    /// @notice Lazy reputation: excess over 0.1 decays 1% per inactive day.
    function reputationOf(address user) public view returns (uint256) {
        Rep memory p = _rep[user];
        if (!p.init) return R_MIN;
        uint256 d = currentDay();
        uint256 r = p.r;
        if (d > p.lastDay && r > R_MIN) {
            r = R_MIN + ((r - R_MIN) * PoFMath.rpow(R_DAILY_KEEP, d - p.lastDay)) / WAD;
        }
        return r;
    }

    function _setRep(address user, uint256 r) internal {
        if (r > R_MAX) r = R_MAX;
        if (r < R_MIN) r = R_MIN;
        _rep[user] = Rep({r: uint64(r), lastDay: uint32(currentDay()), init: true});
    }

    // =====================================================================
    //                    GOVERNANCE (all behind the 7-day timelock)
    // =====================================================================

    function setIdentityGate(address gate) external onlyRole(GOVERNANCE_ROLE) {
        if (gate == address(0)) revert BadParam();
        identityGate = IAgentIdentity(gate);
        emit AddressChanged("identityGate", gate);
    }

    function setRandomness(address rnd) external onlyRole(GOVERNANCE_ROLE) {
        if (rnd == address(0)) revert BadParam();
        randomness = IRandomness(rnd);
        emit AddressChanged("randomness", rnd);
    }

    function setForecastMarket(address fm) external onlyRole(GOVERNANCE_ROLE) {
        forecastMarket = fm;
        emit AddressChanged("forecastMarket", fm);
    }

    function setBountyBoard(address bb) external onlyRole(GOVERNANCE_ROLE) {
        bountyBoard = bb;
        emit AddressChanged("bountyBoard", bb);
    }

    function setForecastEnabled(bool v) external onlyRole(GOVERNANCE_ROLE) {
        forecastEnabled = v;
        emit ParamChanged("forecastEnabled", v ? 1 : 0);
    }

    function setVerifier(address v, bool ok) external onlyRole(GOVERNANCE_ROLE) {
        verifierAllowed[v] = ok;
        emit AddressChanged(ok ? bytes32("verifierOn") : bytes32("verifierOff"), v);
    }

    function setRoundDuration(uint64 d) external onlyRole(GOVERNANCE_ROLE) {
        if (d < 10 minutes || d > 1 days) revert BadParam();
        roundDuration = d;
        emit ParamChanged("roundDuration", d);
    }

    function setNumRungs(uint8 n) external onlyRole(GOVERNANCE_ROLE) {
        if (n == 0 || n > MAX_RUNGS) revert BadParam();
        numRungs = n;
        emit ParamChanged("numRungs", n);
    }

    function setPhases(uint16 fEnd, uint16 cEnd, uint16 gEnd) external onlyRole(GOVERNANCE_ROLE) {
        if (!(fEnd < cEnd && cEnd < gEnd && gEnd < BPS)) revert BadParam();
        forecastEndBps = fEnd;
        commitEndBps = cEnd;
        genRevealEndBps = gEnd;
    }

    function setVerifierGasLimit(uint256 g) external onlyRole(GOVERNANCE_ROLE) {
        if (g < 100_000 || g > 20_000_000) revert BadParam();
        verifierGasLimit = g;
    }

    /// @notice Scales the decay rate. Checkpoints first so past days are not re-priced.
    function setIndexMultiplier(uint256 m) external onlyRole(ORACLE_ROLE) {
        if (m < MIN_INDEX_MULT || m > MAX_INDEX_MULT) revert BadParam();
        uint256 d = currentDay();
        checkpointDaily = dailyEmissionAt(d);
        checkpointDay = d;
        indexMultiplier = m;
        emit ParamChanged("indexMultiplier", m);
    }

    function paused() public view override(IPoFEngine, Pausable) returns (bool) {
        return super.paused();
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }
}
