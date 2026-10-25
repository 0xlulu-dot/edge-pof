// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/// @title EDGE — Proof of Frontier token
/// @notice Hard cap 100M on *cumulative* mint (burns never re-open headroom).
///         5M liquidity + 3M calibration airdrop at deploy, the remaining 92M can only be
///         minted by the PoF engine (the Minter). No team allocation.
contract EDGEToken is ERC20, ERC20Burnable {
    uint256 public constant MAX_SUPPLY = 100_000_000e18;
    uint256 public constant MINING_CAP = 92_000_000e18;
    uint256 public constant LIQUIDITY_ALLOCATION = 5_000_000e18;
    uint256 public constant AIRDROP_ALLOCATION = 3_000_000e18;

    address public minter;
    address public immutable minterSetter;
    uint256 public totalMinted; // cumulative, never decreases
    uint256 public miningMinted; // cumulative mining mint

    error NotMinter();
    error MinterAlreadySet();
    error MiningCapExceeded();
    error ZeroAddress();

    event MinterSet(address minter);

    constructor(address liquidity, address airdropDistributor) ERC20("Edge", "EDGE") {
        if (liquidity == address(0) || airdropDistributor == address(0)) revert ZeroAddress();
        minterSetter = msg.sender;
        _mintTracked(liquidity, LIQUIDITY_ALLOCATION);
        _mintTracked(airdropDistributor, AIRDROP_ALLOCATION);
    }

    /// @notice One-shot: wire the PoF engine as the only mining minter. Cannot be changed later.
    function setMinter(address minter_) external {
        if (msg.sender != minterSetter) revert NotMinter();
        if (minter != address(0)) revert MinterAlreadySet();
        if (minter_ == address(0)) revert ZeroAddress();
        minter = minter_;
        emit MinterSet(minter_);
    }

    function mintMining(address to, uint256 amount) external {
        if (msg.sender != minter) revert NotMinter();
        if (miningMinted + amount > MINING_CAP) revert MiningCapExceeded();
        miningMinted += amount;
        _mintTracked(to, amount);
    }

    function _mintTracked(address to, uint256 amount) internal {
        totalMinted += amount;
        require(totalMinted <= MAX_SUPPLY, "cap");
        _mint(to, amount);
    }
}
