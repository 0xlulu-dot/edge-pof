// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IVerifier} from "../interfaces/IVerifier.sol";

/// @title ConstraintScheduleVerifier — small constraint-satisfaction scheduling family.
/// params = abi.encode(uint256 numTasks, uint256 numSlots, uint256[3][] constraints)
///   constraint = [kind, a, b]
///     kind 0: CONFLICT    slot[a] != slot[b]
///     kind 1: PRECEDENCE  slot[a] <  slot[b]
///     kind 2: FIXED       slot[a] == b
///     kind 3: CAPACITY    at most b tasks in slot a
/// answer = abi.encode(uint256[] slotOfTask)   length numTasks, each < numSlots
contract ConstraintScheduleVerifier is IVerifier {
    uint256 public constant MAX_TASKS = 64;
    uint256 public constant MAX_SLOTS = 64;

    function verify(bytes calldata params, bytes calldata answer) external pure returns (bool) {
        (uint256 nT, uint256 nS, uint256[3][] memory cs) = abi.decode(params, (uint256, uint256, uint256[3][]));
        uint256[] memory slot = abi.decode(answer, (uint256[]));
        if (nT == 0 || nT > MAX_TASKS || nS == 0 || nS > MAX_SLOTS || slot.length != nT) return false;
        for (uint256 i = 0; i < nT; i++) {
            if (slot[i] >= nS) return false;
        }
        for (uint256 j = 0; j < cs.length; j++) {
            uint256 kind = cs[j][0];
            uint256 a = cs[j][1];
            uint256 b = cs[j][2];
            if (kind == 0) {
                if (a >= nT || b >= nT || slot[a] == slot[b]) return false;
            } else if (kind == 1) {
                if (a >= nT || b >= nT || slot[a] >= slot[b]) return false;
            } else if (kind == 2) {
                if (a >= nT || slot[a] != b) return false;
            } else if (kind == 3) {
                uint256 cnt;
                for (uint256 i = 0; i < nT; i++) {
                    if (slot[i] == a) cnt++;
                }
                if (cnt > b) return false;
            } else {
                return false;
            }
        }
        return true;
    }
}
