// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IRandomness} from "../interfaces/IRandomness.sol";

/// @notice Test randomness. `autoFulfill` = seed is ready in the same tx (insecure, tests only).
contract MockRandomness is IRandomness {
    bool public autoFulfill = true;
    mapping(uint256 => uint256) internal _seed;
    mapping(uint256 => bool) internal _ready;

    function setAutoFulfill(bool v) external {
        autoFulfill = v;
    }

    function requestSeed(uint256 roundId) external {
        if (autoFulfill) {
            _seed[roundId] = uint256(keccak256(abi.encode(block.prevrandao, roundId, msg.sender)));
            _ready[roundId] = true;
        }
    }

    function fulfill(uint256 roundId, uint256 seed) external {
        _seed[roundId] = seed;
        _ready[roundId] = true;
    }

    function seedOf(uint256 roundId) external view returns (bool, uint256) {
        return (_ready[roundId], _seed[roundId]);
    }
}
