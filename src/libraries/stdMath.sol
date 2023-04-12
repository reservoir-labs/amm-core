// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

// Our gas-optimized implementation of forge-std's stdMath library
// We should inherit and override the relevant functions in the future when they make them virtual
library stdMath {
    function delta(uint256 a, uint256 b) internal pure returns (uint256) {
        // SAFETY: The subtraction can never underflow as we explicitly sub the
        // smaller value from the larger.
        unchecked {
            return a > b ? a - b : b - a;
        }
    }

    function percentDelta(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 absDelta = delta(a, b);

        return absDelta * 1e18 / b;
    }
}
