// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/// @title AirdropDistributor — 3M EDGE calibration airdrop via Merkle claim.
/// leaf = keccak256(bytes.concat(keccak256(abi.encode(account, amount))))  (OZ standard tree)
/// After `claimDeadline`, anyone can burn the unclaimed remainder (no admin sweep to a wallet).
contract AirdropDistributor {
    using SafeERC20 for IERC20;

    address public immutable deployer;
    bytes32 public immutable merkleRoot;
    uint256 public immutable claimDeadline;
    IERC20 public token;
    mapping(address => bool) public claimed;

    event Claimed(address indexed account, uint256 amount);
    event RemainderBurned(uint256 amount);

    constructor(bytes32 root, uint256 deadline) {
        deployer = msg.sender;
        merkleRoot = root;
        claimDeadline = deadline;
    }

    /// @notice One-shot wiring (token is deployed after this contract and mints 3M to it).
    function initToken(IERC20 token_) external {
        require(msg.sender == deployer && address(token) == address(0), "init");
        token = token_;
    }

    function claim(address account, uint256 amount, bytes32[] calldata proof) external {
        require(block.timestamp < claimDeadline, "ended");
        require(!claimed[account], "claimed");
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(account, amount))));
        require(MerkleProof.verify(proof, merkleRoot, leaf), "proof");
        claimed[account] = true;
        token.safeTransfer(account, amount);
        emit Claimed(account, amount);
    }

    function burnRemainder() external {
        require(block.timestamp >= claimDeadline, "active");
        uint256 bal = token.balanceOf(address(this));
        ERC20Burnable(address(token)).burn(bal);
        emit RemainderBurned(bal);
    }
}
