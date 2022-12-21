// SPDX-License-Identifier: GPL-3.0-or-later
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

pragma solidity ^0.8.0;

import { FixedPointMathLib } from "solmate/utils/FixedPointMathLib.sol";

import { Math } from "src/libraries/Math.sol";
import { LogCompression } from "src/libraries/LogCompression.sol";

library ConstantProductOracleMath {
    using FixedPointMathLib for uint256;

    /**
     * @notice Calculates the spot price of token1/token0 for the constant product pair
     * @dev Minimum price is 1e-18, as we do not round to zero
     * @param reserve0 should never be 0, as checked by _updateAndUnlock()
     * @param reserve1 should never be 0, as checked by _updateAndUnlock()
     */
    function calcLogPrice(uint256 reserve0, uint256 reserve1)
        internal
        pure
        returns (uint256 spotPrice, int112 logSpotPrice)
    {
        // scaled by 1e18
        // spotPrice will never be zero as we do a divWadUp
        // the minimum price would be 1 wei (1e-18)
        spotPrice = reserve1.divWadUp(reserve0);

        int256 rawResult = LogCompression.toLowResLog(spotPrice);
        assert(rawResult >= type(int112).min && rawResult <= type(int112).max);
        logSpotPrice = int112(rawResult);
    }

    // TODO: De-dupe between StableOracleMath and ConstantProductOracleMath
    /// @param reserve0 amount in native precision
    /// @param reserve1 amount in native precision
    function calcLogLiq(uint256 reserve0, uint256 reserve1) internal pure returns (int112 logLiq) {
        uint256 sqrtK = Math.sqrt(reserve0 * reserve1);

        int256 rawResult = LogCompression.toLowResLog(sqrtK);
        assert(rawResult >= type(int112).min && rawResult <= type(int112).max);
        logLiq = int112(rawResult);
    }
}
