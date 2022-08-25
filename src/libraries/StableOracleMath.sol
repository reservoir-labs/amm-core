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

pragma solidity 0.8.13;

import "src/libraries/LogCompression.sol";
import "src/libraries/FixedPoint.sol";

import "src/libraries/StableMath.sol";

// These functions start with an underscore, as if they were part of a contract and not a library. At some point this
// should be fixed.
// solhint-disable private-vars-leading-underscore

library StableOracleMath {
    using FixedPoint for uint256;

    /**
     * @dev Calculates the spot price of token1/token0
     */
    function _calcLogPrice(
        uint256 amplificationParameter,
        uint256 reserve0,
        uint256 reserve1
    ) internal pure returns (int256 logSpotPrice) {

        // scaled by 1e18
        uint256 spotPrice;

        // amplification parameter only applies for stableswap
        if (amplificationParameter == 0) {
            spotPrice = reserve1 * 1e18 / reserve0;
        }
        // stableswap
        else {
            spotPrice = _calcStableSpotPrice(amplificationParameter, reserve0, reserve1);
        }
        logSpotPrice = LogCompression.toLowResLog(spotPrice);
    }

    /**
     * @dev Calculates the spot price of token Y in token X.
     */
    function _calcStableSpotPrice(
        uint256 amplificationParameter,
        uint256 balanceX,
        uint256 balanceY
    ) internal pure returns (uint256) {
        /**************************************************************************************************************
        //                                                                                                           //
        //                             2.a.x.y + a.y^2 + b.y                                                         //
        // spot price Y/X = - dx/dy = -----------------------                                                        //
        //                             2.a.x.y + a.x^2 + b.x                                                         //
        //                                                                                                           //
        // n = 2                                                                                                     //
        // a = amp param * n                                                                                         //
        // b = D + a.(S - D)                                                                                         //
        // D = invariant                                                                                             //
        // S = sum of balances but x,y = 0 since x  and y are the only tokens                                        //
        **************************************************************************************************************/

        uint256 invariant = StableMath._computeLiquidityFromAdjustedBalances(balanceX, balanceY, 2 * amplificationParameter);

        uint256 a = (amplificationParameter * 2) / StableMath.A_PRECISION;
        uint256 b = (invariant * a).sub(invariant);

        uint256 axy2 = (a * 2 * balanceX).mulDown(balanceY); // n = 2

        // dx = a.x.y.2 + a.y^2 - b.y
        uint256 derivativeX = axy2.add((a * balanceY).mulDown(balanceY)).sub(b.mulDown(balanceY));

        // dy = a.x.y.2 + a.x^2 - b.x
        uint256 derivativeY = axy2.add((a * balanceX).mulDown(balanceX)).sub(b.mulDown(balanceX));

        // The rounding direction is irrelevant as we're about to introduce a much larger error when converting to log
        // space. We use `divUp` as it prevents the result from being zero, which would make the logarithm revert. A
        // result of zero is therefore only possible with zero balances, which are prevented via other means.
        return derivativeX.divUp(derivativeY);
    }
}
