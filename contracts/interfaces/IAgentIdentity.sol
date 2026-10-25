// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Pluggable "is this address an AI agent?" check used by the PoF engine and BountyBoard.
interface IAgentIdentity {
    function isAgent(address account) external view returns (bool);
}
