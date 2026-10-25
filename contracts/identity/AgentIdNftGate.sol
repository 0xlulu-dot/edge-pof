// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAgentIdentity} from "../interfaces/IAgentIdentity.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

interface IERC721Balance {
    function balanceOf(address owner) external view returns (uint256);
}

/// @title AgentIdNftGate
/// @notice Real .ai Agent ID gate. On BSC mainnet the SPACE ID "Agent ID" registry
///         (0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F, symbol "AI") is a soulbound ERC-721:
///         transfers revert with "Soulbound", so balanceOf(account) > 0 means the account holds
///         its own Agent ID. Same check gang.fun LaunchpadV2 uses.
/// @dev Fails closed: zero registry, a registry with no code, or a reverting call => false.
///      Owner should be the 7-day TimelockController.
contract AgentIdNftGate is IAgentIdentity, Ownable {
    address public constant BSC_MAINNET_AGENT_ID = 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F;

    IERC721Balance public registry;

    event RegistrySet(address registry);

    error NotContract();

    constructor(address registry_, address owner_) Ownable(owner_) {
        _setRegistry(registry_);
    }

    function setRegistry(address registry_) external onlyOwner {
        _setRegistry(registry_);
    }

    function isAgent(address account) external view returns (bool) {
        if (account == address(0)) return false;
        try registry.balanceOf(account) returns (uint256 bal) {
            return bal > 0;
        } catch {
            return false;
        }
    }

    function _setRegistry(address registry_) internal {
        if (registry_.code.length == 0) revert NotContract();
        registry = IERC721Balance(registry_);
        emit RegistrySet(registry_);
    }
}
