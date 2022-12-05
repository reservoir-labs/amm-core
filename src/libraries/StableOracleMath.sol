pragma solidity ^0.8.0;

import { FixedPointMathLib } from "solmate/utils/FixedPointMathLib.sol";

import { Math } from "src/libraries/Math.sol";
import { LogCompression } from "src/libraries/LogCompression.sol";
import { StableMath } from "src/libraries/StableMath.sol";

library StableOracleMath {
    using FixedPointMathLib for uint256;

    /**
     * @dev Calculates the spot price of token1/token0 for the stable pair
     */
    function calcLogPrice(uint256 amplificationParameter, uint256 reserve0, uint256 reserve1)
        internal
        pure
        returns (uint256 spotPrice, int112 logSpotPrice)
    {
        spotPrice = calcSpotPrice(amplificationParameter, reserve0, reserve1);

        int256 rawLogSpotPrice = LogCompression.toLowResLog(spotPrice);
        assert(rawLogSpotPrice >= type(int112).min && rawLogSpotPrice <= type(int112).max);
        logSpotPrice = int112(rawLogSpotPrice);
    }

    /**
     * @dev Calculates the spot price of token1 in token0
     */
    function calcSpotPrice(uint256 amplificationParameter, uint256 reserve0, uint256 reserve1)
        internal
        pure
        returns (uint256 spotPrice)
    {
        /**
         *
         *     //                                                                                                           //
         *     //                             2.a.x.y + a.y^2 + b.y                                                         //
         *     // spot price Y/X = - dx/dy = -----------------------                                                        //
         *     //                             2.a.x.y + a.x^2 + b.x                                                         //
         *     //                                                                                                           //
         *     // n = 2                                                                                                     //
         *     // a = amp param * n                                                                                         //
         *     // b = D + a.(S - D)                                                                                         //
         *     // D = invariant                                                                                             //
         *     // S = sum of balances but x,y = 0 since x  and y are the only tokens                                        //
         *
         */

        uint256 invariant =
            StableMath._computeLiquidityFromAdjustedBalances(reserve0, reserve1, 2 * amplificationParameter);

        uint256 a = (amplificationParameter * 2) / StableMath.A_PRECISION;
        uint256 b = (invariant * a) - invariant;

        uint256 axy2 = (a * 2 * reserve0).mulWadDown(reserve1); // n = 2

        // dx = a.x.y.2 + a.y^2 - b.y
        uint256 derivativeX = axy2 + ((a * reserve1).mulWadDown(reserve1)) - (b.mulWadDown(reserve1));

        // dy = a.x.y.2 + a.x^2 - b.x
        uint256 derivativeY = axy2 + ((a * reserve0).mulWadDown(reserve0)) - (b.mulWadDown(reserve0));

        // The rounding direction is irrelevant as we're about to introduce a much larger error when converting to log
        // space. We use `divWadUp` as it prevents the result from being zero, which would make the logarithm revert. A
        // result of zero is therefore only possible with zero balances, which are prevented via other means.
        spotPrice = derivativeX.divWadUp(derivativeY);
    }

    /// @param reserve0 amount in native precision
    /// @param reserve1 amount in native precision
    function calcLogLiq(uint256 reserve0, uint256 reserve1) internal pure returns (int112 logLiq) {
        uint256 sqrtK = Math.sqrt(reserve0 * reserve1);

        int256 rawResult = LogCompression.toLowResLog(sqrtK);
        assert(rawResult >= type(int112).min && rawResult <= type(int112).max);
        logLiq = int112(rawResult);
    }
}
