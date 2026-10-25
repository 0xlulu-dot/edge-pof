// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAgentIdentity} from "../interfaces/IAgentIdentity.sol";

/// @notice Test/testnet gate: an owner-managed allowlist. NEVER use on mainnet.
contract MockAgentGate is IAgentIdentity {
    address public owner;
    mapping(address => bool) public agent;

    constructor() {
        owner = msg.sender;
    }

    function setAgent(address a, bool ok) external {
        require(msg.sender == owner, "owner");
        agent[a] = ok;
    }

    function isAgent(address a) external view returns (bool) {
        return agent[a];
    }
}
