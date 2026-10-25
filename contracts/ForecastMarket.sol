// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoFEngine} from "./interfaces/IPoFEngine.sol";

/// @title ForecastMarket — forecasters predict how crowded each rung will be.
/// @notice Only active when `engine.forecastEnabled()` (default false).
///  1. stake EDGE (7-day unbonding to withdraw)
///  2. before puzzles are posted, submit per-rung probabilities over buckets {0, <2, 2..k, >k}
///  3. after settlement, anyone calls score(): Brier vs. the uniform baseline (0.75)
///       better than baseline -> weight = sqrt(stake) * (baseline - brier)
///       worse than baseline  -> 10% of the stake used is slashed (burned)
///  4. after the scoring window, claim(): share of the round's 20% forecaster pool, with each
///     address capped at 2% of total weight (anti-whale). Unclaimed/capped remainder is swept
///     back to the engine (50% burned, 50% rolled over).
contract ForecastMarket is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    uint256 internal constant WAD = 1e18;
    uint256 public constant BUCKETS = 4;
    uint256 public constant BASELINE_BRIER = 75e16; // uniform 0.25 x4 -> 0.75
    uint256 public constant SLASH_BPS = 1_000; // 10%
    uint256 public constant WEIGHT_CAP_BPS = 200; // 2% of total weight per address
    uint256 public constant UNBONDING = 7 days;

    IERC20 public immutable edge;
    IPoFEngine public immutable engine;
    uint256 public minStake = 100e18;
    uint64 public scoreWindow = 2 days;
    uint64 public claimWindow = 5 days; // after scoreWindow

    struct Unbond {
        uint256 amount;
        uint64 release;
    }

    struct Forecast {
        bool submitted;
        bool scored;
        bool claimed;
        uint256 stakeUsed;
        uint256 brier;
        uint256 weight;
    }

    mapping(address => uint256) public staked;
    mapping(address => Unbond) public unbonding;
    mapping(uint256 => mapping(address => Forecast)) public forecasts;
    mapping(uint256 => mapping(address => uint256[])) internal _probs; // flattened [rung*4+bucket]
    mapping(uint256 => uint256) public totalWeight;
    mapping(uint256 => bool) public swept;

    event Staked(address indexed user, uint256 amount);
    event UnbondRequested(address indexed user, uint256 amount, uint64 release);
    event Withdrawn(address indexed user, uint256 amount);
    event ForecastSubmitted(uint256 indexed roundId, address indexed user);
    event Scored(uint256 indexed roundId, address indexed user, uint256 brier, uint256 weight, uint256 slashed);
    event ForecastClaimed(uint256 indexed roundId, address indexed user, uint256 amount);

    error BadPhase();
    error BadParam();

    constructor(IERC20 edge_, IPoFEngine engine_, address admin) {
        edge = edge_;
        engine = engine_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GOVERNANCE_ROLE, admin);
    }

    // ------------------------- staking -------------------------
    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert BadParam();
        staked[msg.sender] += amount;
        edge.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);
    }

    /// @notice Starts (or tops up and restarts) the 7-day unbonding clock.
    function requestUnbond(uint256 amount) external {
        if (amount == 0 || amount > staked[msg.sender]) revert BadParam();
        staked[msg.sender] -= amount;
        Unbond storage u = unbonding[msg.sender];
        u.amount += amount;
        u.release = uint64(block.timestamp + UNBONDING);
        emit UnbondRequested(msg.sender, amount, u.release);
    }

    /// @notice Never paused.
    function withdraw() external nonReentrant {
        Unbond storage u = unbonding[msg.sender];
        if (u.amount == 0 || block.timestamp < u.release) revert BadPhase();
        uint256 amt = u.amount;
        u.amount = 0;
        edge.safeTransfer(msg.sender, amt);
        emit Withdrawn(msg.sender, amt);
    }

    // ------------------------- forecasting -------------------------
    /// @param probs flattened numRungs x 4 matrix, each row sums to 1e18
    function submitForecast(uint256 roundId, uint256[] calldata probs) external {
        if (!engine.forecastEnabled()) revert BadPhase();
        IPoFEngine.ForecastView memory v = engine.forecastView(roundId);
        if (v.start == 0 || v.puzzlesPosted || block.timestamp >= v.forecastEnd) revert BadPhase();
        if (probs.length != uint256(v.numRungs) * BUCKETS) revert BadParam();
        uint256 s = staked[msg.sender];
        if (s < minStake) revert BadParam();
        Forecast storage f = forecasts[roundId][msg.sender];
        if (f.submitted) revert BadPhase();
        for (uint256 r = 0; r < v.numRungs; r++) {
            uint256 sum;
            for (uint256 b = 0; b < BUCKETS; b++) {
                sum += probs[r * BUCKETS + b];
            }
            if (sum != WAD) revert BadParam();
        }
        f.submitted = true;
        f.stakeUsed = s;
        _probs[roundId][msg.sender] = probs;
        emit ForecastSubmitted(roundId, msg.sender);
    }

    function brierOf(uint256 roundId, address user) public view returns (uint256) {
        uint256[] storage p = _probs[roundId][user];
        uint256 n = p.length / BUCKETS;
        uint256 total;
        for (uint8 r = 0; r < n; r++) {
            uint8 o = engine.rungBucket(roundId, r);
            for (uint256 b = 0; b < BUCKETS; b++) {
                uint256 pb = p[r * BUCKETS + b];
                uint256 ob = b == o ? WAD : 0;
                uint256 d = pb > ob ? pb - ob : ob - pb;
                total += (d * d) / WAD;
            }
        }
        return total / n;
    }

    /// @notice Permissionless scoring during the scoring window.
    function score(uint256 roundId, address user) external nonReentrant {
        IPoFEngine.ForecastView memory v = engine.forecastView(roundId);
        if (!v.settled || block.timestamp >= uint256(v.settledAt) + scoreWindow) revert BadPhase();
        Forecast storage f = forecasts[roundId][user];
        if (!f.submitted || f.scored) revert BadPhase();
        f.scored = true;
        uint256 brier = brierOf(roundId, user);
        f.brier = brier;
        uint256 slashed;
        if (brier < BASELINE_BRIER) {
            uint256 w = Math.sqrt(f.stakeUsed) * (BASELINE_BRIER - brier);
            f.weight = w;
            totalWeight[roundId] += w;
        } else if (brier > BASELINE_BRIER) {
            slashed = _slash(user, (f.stakeUsed * SLASH_BPS) / 10_000);
        }
        emit Scored(roundId, user, brier, f.weight, slashed);
    }

    function _slash(address user, uint256 amt) internal returns (uint256 taken) {
        uint256 s = staked[user];
        uint256 fromStake = amt > s ? s : amt;
        staked[user] = s - fromStake;
        taken = fromStake;
        if (taken < amt) {
            Unbond storage u = unbonding[user];
            uint256 rest = amt - taken;
            uint256 fromU = rest > u.amount ? u.amount : rest;
            u.amount -= fromU;
            taken += fromU;
        }
        if (taken > 0) ERC20Burnable(address(edge)).burn(taken);
    }

    function cappedWeight(uint256 roundId, address user) public view returns (uint256) {
        uint256 w = forecasts[roundId][user].weight;
        uint256 cap = (totalWeight[roundId] * WEIGHT_CAP_BPS) / 10_000;
        return w > cap ? cap : w;
    }

    function claim(uint256 roundId) external nonReentrant returns (uint256 amt) {
        IPoFEngine.ForecastView memory v = engine.forecastView(roundId);
        uint256 opens = uint256(v.settledAt) + scoreWindow;
        if (!v.settled || block.timestamp < opens || block.timestamp >= opens + claimWindow) revert BadPhase();
        Forecast storage f = forecasts[roundId][msg.sender];
        if (!f.scored || f.claimed || f.weight == 0) revert BadPhase();
        f.claimed = true;
        amt = (engine.forecastBudget(roundId) * cappedWeight(roundId, msg.sender)) / totalWeight[roundId];
        engine.creditForecast(roundId, msg.sender, amt);
        emit ForecastClaimed(roundId, msg.sender, amt);
    }

    /// @notice After the claim window: return whatever was not paid (caps, no-shows) to the engine.
    function sweep(uint256 roundId) external {
        IPoFEngine.ForecastView memory v = engine.forecastView(roundId);
        if (!v.settled || block.timestamp < uint256(v.settledAt) + scoreWindow + claimWindow) revert BadPhase();
        if (swept[roundId]) revert BadPhase();
        swept[roundId] = true;
        engine.returnForecastUnused(roundId);
    }

    function setMinStake(uint256 m) external onlyRole(GOVERNANCE_ROLE) {
        minStake = m;
    }

    function setWindows(uint64 s, uint64 c) external onlyRole(GOVERNANCE_ROLE) {
        // score window must stay below the 7-day unbonding so slashes can still reach stake
        if (s == 0 || s >= UNBONDING || c == 0) revert BadParam();
        scoreWindow = s;
        claimWindow = c;
    }
}
