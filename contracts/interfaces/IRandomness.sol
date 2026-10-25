// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice VRF-consumer abstraction. Engine requests a seed per round; the generator may only
/// post puzzles once the seed is ready (the off-chain/TEE generator derives puzzles from it).
interface IRandomness {
    function requestSeed(uint256 roundId) external;
    function seedOf(uint256 roundId) external view returns (bool ready, uint256 seed);
}
