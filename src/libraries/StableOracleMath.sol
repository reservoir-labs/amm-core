pragma solidity 0.8.13;

import "solmate/utils/FixedPointMathLib.sol";

import "src/libraries/Math.sol";
import "src/libraries/LogCompression.sol";
import "src/libraries/StableMath.sol";

// todo: to make calculating price and liquidity one function as liquidity is just the invariant for StablePair
library StableOracleMath {
    using FixedPointMathLib for uint256;

    /**
     * @dev Calculates the spot price of token1/token0 for the stable pair
     */
    function calcLogPrice(
        uint256 amplificationParameter,
        uint256 reserve0,
        uint256 reserve1
    ) internal pure returns (int112 logSpotPrice) {
        uint256 spotPrice = calcStableSpotPrice(amplificationParameter, reserve0, reserve1);
        int256 rawResult = LogCompression.toLowResLog(spotPrice);
        assert(rawResult >= type(int112).min && rawResult <= type(int112).max);
        logSpotPrice = int112(rawResult);
    }

    /**
     * @dev Calculates the spot price of token1 in token0
     */
    function calcStableSpotPrice(
        uint256 amplificationParameter,
        uint256 reserve0,
        uint256 reserve1
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

        uint256 invariant = StableMath._computeLiquidityFromAdjustedBalances(reserve0, reserve1, 2 * amplificationParameter);

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
        return derivativeX.divWadUp(derivativeY);
    }
}