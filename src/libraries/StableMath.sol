pragma solidity ^0.8.0;

import "src/libraries/MathUtils.sol";
import { stdMath } from "forge-std/Test.sol";

library StableMath {
    using MathUtils for uint;

    /// @dev extra precision for intermediate calculations
    uint public constant A_PRECISION = 100;
    /// @dev minimum time to the ramp A
    uint public constant MIN_RAMP_TIME = 1 days;
    /// @dev minimum amplification coefficient for the math to work
    uint public constant MIN_A = 1;
    /// @dev maximum amplification coefficient
    uint public constant MAX_A = 10_000;
    /// @dev maximum rate of change daily
    /// it is possible to change A by a factor of 8 over 3 days (2 ** 3)
    uint public constant MAX_AMP_UPDATE_DAILY_RATE = 2;
    /// @dev required as an upper limit for iterative calculations not guaranteed to converge
    uint private constant MAX_LOOP_LIMIT = 256;
    /// @dev 100%
    uint private constant MAX_FEE = 1_000_000;

    function _getAmountOut(
        uint amountIn,
        uint reserve0,
        uint reserve1,
        uint token0PrecisionMultiplier,
        uint token1PrecisionMultiplier,
        bool token0In,
        uint swapFee,
        uint N_A // solhint-disable-line var-name-mixedcase
    ) internal pure returns (uint dy) {
        unchecked {
            uint adjustedReserve0 = reserve0 * token0PrecisionMultiplier;
            uint adjustedReserve1 = reserve1 * token1PrecisionMultiplier;
            uint feeDeductedAmountIn = amountIn - (amountIn * swapFee) / MAX_FEE;
            uint d = _computeLiquidityFromAdjustedBalances(adjustedReserve0, adjustedReserve1, N_A);

            if (token0In) {
                uint x = adjustedReserve0 + (feeDeductedAmountIn * token0PrecisionMultiplier);
                uint y = _getY(x, d, N_A);
                dy = adjustedReserve1 - y - 1;
                dy /= token1PrecisionMultiplier;
            } else {
                uint x = adjustedReserve1 + (feeDeductedAmountIn * token1PrecisionMultiplier);
                uint y = _getY(x, d, N_A);
                dy = adjustedReserve0 - y - 1;
                dy /= token0PrecisionMultiplier;
            }
        }
    }

    function _getAmountIn(
        uint amountOut,
        uint reserve0,
        uint reserve1,
        uint token0PrecisionMultiplier,
        uint token1PrecisionMultiplier,
        bool token0Out,
        uint swapFee,
        uint N_A // solhint-disable-line var-name-mixedcase
    ) internal pure returns (uint dx) {
        unchecked {
            uint adjustedReserve0 = reserve0 * token0PrecisionMultiplier;
            uint adjustedReserve1 = reserve1 * token1PrecisionMultiplier;
            uint d = _computeLiquidityFromAdjustedBalances(adjustedReserve0, adjustedReserve1, N_A);

            if (token0Out) {
                uint y = adjustedReserve0 - amountOut * token0PrecisionMultiplier;
                uint x = _getY(y, d, N_A);
                dx = x - adjustedReserve1 + 1;
                dx /= token1PrecisionMultiplier;
            } else {
                uint y = adjustedReserve1 - amountOut * token1PrecisionMultiplier;
                uint x = _getY(y, d, N_A);
                dx = x - adjustedReserve0 + 1;
                dx /= token0PrecisionMultiplier;
            }
            // add the swap fee
            dx = dx * (MAX_FEE + swapFee) / MAX_FEE;
        }
    }

    function _computeLiquidityFromAdjustedBalances(
        uint xp0,
        uint xp1,
        uint N_A // solhint-disable-line var-name-mixedcase
    ) internal pure returns (uint) {
        uint s = xp0 + xp1;
        if (s == 0) {
            return 0;
        }

        uint prevD;
        // solhint-disable-next-line var-name-mixedcase
        uint D = s;
        (xp0, xp1) = xp0 < xp1 ? (xp0, xp1) : (xp1, xp0);
        for (uint i = 0; i < MAX_LOOP_LIMIT; i++) {
            uint dP = (((D * D) / xp0) * D) / xp1 / 4;
            prevD = D;
            D = (((N_A * s) / A_PRECISION + 2 * dP) * D) / ((N_A - A_PRECISION) * D / A_PRECISION + 3 * dP);
            if (D.within1(prevD)) {
                return D;
            }
        }
        // sometimes the iteration gets stuck in an oscillating loop
        // so if it is close enough we return it anyway
        uint percentDelta = stdMath.percentDelta(D, prevD);
        if (percentDelta <= 0.0000000000004e18) {
            return (D + prevD) / 2;
        }

        revert("SM: COMPUTE_DID_NOT_CONVERGE");
    }

    /// @notice Calculate the new balance of one token given the balance of the other token
    /// This function is used as a helper function to calculate how much TO/FROM token
    /// the user should receive/provide on swap.
    /// @dev Originally
    /// https://github.com/saddle-finance/saddle-contract/blob/0b76f7fb519e34b878aa1d58cffc8d8dc0572c12/contracts/SwapUtils.sol#L432.
    /// @param x The new total amount of FROM/TO token.
    /// @return y The amount of TO/FROM token that should remain in the pool.
    function _getY(
        uint x,
        uint D, // solhint-disable-line var-name-mixedcase
        uint N_A // solhint-disable-line var-name-mixedcase
    ) internal pure returns (uint y) {
        uint c = (D * D) / (x * 2);
        c = (c * D) * A_PRECISION / (N_A * 2);
        uint b = x + ((D * A_PRECISION) / N_A);
        uint yPrev;
        y = D;
        // @dev Iterative approximation.
        for (uint i = 0; i < MAX_LOOP_LIMIT; i++) {
            yPrev = y;
            y = (y * y + c) / (y * 2 + b - D);
            if (y.within1(yPrev)) {
                return y;
            }
        }
        revert("SM: GETY_DID_NOT_CONVERGE");
    }
}
