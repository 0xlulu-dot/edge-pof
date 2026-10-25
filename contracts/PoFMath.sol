// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title PoFMath — pure math shared by the engine, tests and the simulation spec.
library PoFMath {
    uint256 internal constant WAD = 1e18;

    /// @notice x^n in WAD fixed point (exponentiation by squaring). x <= WAD in our usage.
    function rpow(uint256 x, uint256 n) internal pure returns (uint256 z) {
        z = WAD;
        while (n > 0) {
            if (n & 1 == 1) z = (z * x) / WAD;
            x = (x * x) / WAD;
            n >>= 1;
        }
    }

    /// @notice k = clamp(floor(sqrt(activeIDs)/10), 3, 30)
    function kFor(uint256 activeIDs) internal pure returns (uint256 k) {
        k = Math.sqrt(activeIDs) / 10;
        if (k < 3) k = 3;
        if (k > 30) k = 30;
    }

    /// @notice crowding factor g(n_eff) in WAD. nEff is WAD-scaled (sum of reputations).
    ///   n_eff == 0      -> 0
    ///   0 < n_eff < 2   -> 0.7
    ///   2 <= n_eff <= k -> 1
    ///   n_eff > k       -> k / n_eff
    function g(uint256 nEff, uint256 k) internal pure returns (uint256) {
        if (nEff == 0) return 0;
        if (nEff < 2 * WAD) return 7e17;
        if (nEff <= k * WAD) return WAD;
        return (k * WAD * WAD) / nEff;
    }

    /// @notice outcome bucket of a rung used by the forecast market: 0 | <2 | 2..k | >k
    function bucket(uint256 nEff, uint256 k) internal pure returns (uint8) {
        if (nEff == 0) return 0;
        if (nEff < 2 * WAD) return 1;
        if (nEff <= k * WAD) return 2;
        return 3;
    }
}
