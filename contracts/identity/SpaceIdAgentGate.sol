// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAgentIdentity} from "../interfaces/IAgentIdentity.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice ASSUMED minimal interface for a SPACE ID reverse lookup (address -> primary name).
/// TODO(SPACE ID): the real SPACE ID ".ai" TLD contracts / ABI are NOT known yet. Replace this
/// with the official reverse registrar + resolver (likely ENS-style: reverse node -> name, plus a
/// forward-resolution check that the name resolves back to the same address), and confirm the
/// exact TLD string / chain deployment on BSC.
interface ISidReverseLookup {
    function getName(address account) external view returns (string memory);
}

/// @title SpaceIdAgentGate
/// @notice Passes if `account` has a primary name ending in ".ai" according to the configured
/// lookup contract. Owner (should be the 7-day TimelockController) can swap the lookup address.
contract SpaceIdAgentGate is IAgentIdentity, Ownable {
    ISidReverseLookup public lookup;
    bytes public constant SUFFIX = ".ai";

    event LookupSet(address lookup);

    constructor(address lookup_, address owner_) Ownable(owner_) {
        lookup = ISidReverseLookup(lookup_);
        emit LookupSet(lookup_);
    }

    function setLookup(address lookup_) external onlyOwner {
        lookup = ISidReverseLookup(lookup_);
        emit LookupSet(lookup_);
    }

    function isAgent(address account) external view returns (bool) {
        if (address(lookup) == address(0)) return false;
        try lookup.getName(account) returns (string memory n) {
            return _hasAiSuffix(bytes(n));
        } catch {
            return false;
        }
    }

    function _hasAiSuffix(bytes memory n) internal pure returns (bool) {
        uint256 s = SUFFIX.length;
        if (n.length <= s) return false; // need at least one label char
        for (uint256 i = 0; i < s; i++) {
            if (n[n.length - s + i] != SUFFIX[i]) return false;
        }
        return true;
    }
}
