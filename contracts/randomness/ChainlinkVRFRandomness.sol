// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IRandomness} from "../interfaces/IRandomness.sol";

/// TODO(Chainlink VRF): STUB ONLY — untested, not wired in Deploy.s.sol by default.
/// Replace this assumed interface with the official Chainlink VRF v2.5 contracts
/// (`VRFConsumerBaseV2Plus`, `VRFV2PlusClient.RandomWordsRequest`) and the BSC coordinator
/// address / keyHash / subscription id from Chainlink docs.
interface IAssumedVRFCoordinator {
    function requestRandomWords(
        bytes32 keyHash,
        uint256 subId,
        uint16 requestConfirmations,
        uint32 callbackGasLimit,
        uint32 numWords
    ) external returns (uint256 requestId);
}

contract ChainlinkVRFRandomness is IRandomness {
    IAssumedVRFCoordinator public immutable coordinator;
    bytes32 public immutable keyHash;
    uint256 public immutable subId;
    address public immutable engine;

    mapping(uint256 => uint256) public requestToRound;
    mapping(uint256 => uint256) internal _seed;
    mapping(uint256 => bool) internal _ready;

    constructor(address coordinator_, bytes32 keyHash_, uint256 subId_, address engine_) {
        coordinator = IAssumedVRFCoordinator(coordinator_);
        keyHash = keyHash_;
        subId = subId_;
        engine = engine_;
    }

    function requestSeed(uint256 roundId) external {
        require(msg.sender == engine, "engine");
        uint256 reqId = coordinator.requestRandomWords(keyHash, subId, 3, 200_000, 1);
        requestToRound[reqId] = roundId;
    }

    /// @dev TODO: real integration must use the base contract's `rawFulfillRandomWords` guard.
    function fulfillRandomWords(uint256 requestId, uint256[] calldata words) external {
        require(msg.sender == address(coordinator), "coordinator");
        uint256 roundId = requestToRound[requestId];
        _seed[roundId] = words[0];
        _ready[roundId] = true;
    }

    function seedOf(uint256 roundId) external view returns (bool, uint256) {
        return (_ready[roundId], _seed[roundId]);
    }
}
