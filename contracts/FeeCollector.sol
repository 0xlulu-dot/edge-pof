// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title FeeCollector — accumulates the 5% bounty protocol fee in three buckets.
///   50% buyback/burn bucket, 40% treasury, 10% dev. Withdrawals by GOVERNANCE (timelock).
///   MVP: the buyback is NOT automated — governance withdraws the bucket and executes it.
contract FeeCollector is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant FEE_SOURCE_ROLE = keccak256("FEE_SOURCE_ROLE");

    uint256 public constant BUYBACK_BPS = 5_000;
    uint256 public constant TREASURY_BPS = 4_000;
    // dev = remainder (10%)

    mapping(address => uint256) public buyback;
    mapping(address => uint256) public treasury;
    mapping(address => uint256) public dev;

    event FeeNotified(address indexed token, uint256 amount, uint256 toBuyback, uint256 toTreasury, uint256 toDev);
    event TreasuryNotified(address indexed token, uint256 amount);
    event Withdrawn(address indexed token, uint8 bucket, address to, uint256 amount);

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GOVERNANCE_ROLE, admin);
    }

    /// @dev caller must have transferred `amount` of `token` to this contract first.
    function notifyFee(address token, uint256 amount) external onlyRole(FEE_SOURCE_ROLE) {
        uint256 b = (amount * BUYBACK_BPS) / 10_000;
        uint256 t = (amount * TREASURY_BPS) / 10_000;
        uint256 d = amount - b - t;
        buyback[token] += b;
        treasury[token] += t;
        dev[token] += d;
        emit FeeNotified(token, amount, b, t, d);
    }

    /// @dev e.g. a slashed publisher stake after a rejected dispute: 100% treasury.
    function notifyTreasury(address token, uint256 amount) external onlyRole(FEE_SOURCE_ROLE) {
        treasury[token] += amount;
        emit TreasuryNotified(token, amount);
    }

    /// @param bucket 0 buyback, 1 treasury, 2 dev
    function withdraw(address token, uint8 bucket, address to, uint256 amount) external onlyRole(GOVERNANCE_ROLE) nonReentrant {
        mapping(address => uint256) storage m = bucket == 0 ? buyback : bucket == 1 ? treasury : dev;
        require(bucket <= 2 && m[token] >= amount, "amount");
        m[token] -= amount;
        IERC20(token).safeTransfer(to, amount);
        emit Withdrawn(token, bucket, to, amount);
    }
}
