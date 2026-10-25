// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IVerifier} from "../interfaces/IVerifier.sol";

/// @title SubsetSumVerifier — classic NP-complete sample family.
/// params = abi.encode(uint256[] set, uint256 target)
/// answer = abi.encode(uint256[] indices)  (strictly increasing, non-empty)
contract SubsetSumVerifier is IVerifier {
    uint256 public constant MAX_SET = 256;

    function verify(bytes calldata params, bytes calldata answer) external pure returns (bool) {
        (uint256[] memory set, uint256 target) = abi.decode(params, (uint256[], uint256));
        uint256[] memory idx = abi.decode(answer, (uint256[]));
        if (set.length > MAX_SET || idx.length == 0 || idx.length > set.length) return false;
        uint256 sum;
        for (uint256 i = 0; i < idx.length; i++) {
            if (idx[i] >= set.length) return false;
            if (i > 0 && idx[i] <= idx[i - 1]) return false;
            unchecked {
                uint256 ns = sum + set[idx[i]];
                if (ns < sum) return false; // overflow
                sum = ns;
            }
        }
        return sum == target;
    }
}
