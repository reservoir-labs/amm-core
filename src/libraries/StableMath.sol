pragma solidity 0.8.13;

import "src/libraries/MathUtils.sol";

library StableMath {
    using MathUtils for uint256;

    uint256 private constant MAX_LOOP_LIMIT = 256;
    uint256 internal constant MAX_FEE = 10000; // @dev 100%.

    function _getAmountOut(
        uint256 amountIn,
        uint256 reserve0,
        uint256 reserve1,
        uint256 token0PrecisionMultiplier,
        uint256 token1PrecisionMultiplier,
        bool token0In,
        uint256 swapFee,
        uint256 N_A,
        uint256 A_PRECISION
    ) internal pure returns(uint256 dy) {
    unchecked {
        uint256 adjustedReserve0 = reserve0 * token0PrecisionMultiplier;
        uint256 adjustedReserve1 = reserve1 * token1PrecisionMultiplier;
        uint256 feeDeductedAmountIn = amountIn - (amountIn * swapFee) / MAX_FEE;
        uint256 d = _computeLiquidityFromAdjustedBalances(adjustedReserve0, adjustedReserve1, N_A, A_PRECISION);

        if (token0In) {
            uint256 x = adjustedReserve0 + (feeDeductedAmountIn * token0PrecisionMultiplier);
            uint256 y = _getY(x, d, N_A, A_PRECISION);
            dy = adjustedReserve1 - y - 1;
            dy /= token1PrecisionMultiplier;
        } else {
            uint256 x = adjustedReserve1 + (feeDeductedAmountIn * token1PrecisionMultiplier);
            uint256 y = _getY(x, d, N_A, A_PRECISION);
            dy = adjustedReserve0 - y - 1;
            dy /= token0PrecisionMultiplier;
        }
    }
    }

    function _computeLiquidityFromAdjustedBalances(
        uint256 xp0,
        uint256 xp1,
        uint256 N_A,
        uint256 A_PRECISION
    ) internal pure returns (uint256 computed) {
        uint256 s = xp0 + xp1;

        if (s == 0) {
            computed = 0;
        }
        uint256 prevD;
        uint256 D = s;
        for (uint256 i = 0; i < MAX_LOOP_LIMIT; i++) {
            uint256 dP = (((D * D) / xp0) * D) / xp1 / 4;
            prevD = D;
            D = (((N_A * s) / A_PRECISION + 2 * dP) * D) / ((N_A / A_PRECISION - 1) * D + 3 * dP);
            if (D.within1(prevD)) {
                break;
            }
        }
        computed = D;
    }

    /// @notice Calculate the new balances of the tokens given the indexes of the token
    /// that is swapped from (FROM) and the token that is swapped to (TO).
    /// This function is used as a helper function to calculate how much TO token
    /// the user should receive on swap.
    /// @dev Originally https://github.com/saddle-finance/saddle-contract/blob/0b76f7fb519e34b878aa1d58cffc8d8dc0572c12/contracts/SwapUtils.sol#L432.
    /// @param x The new total amount of FROM token.
    /// @return y The amount of TO token that should remain in the pool.
    function _getY(
        uint256 x,
        uint256 D,
        uint256 N_A,
        uint256 A_PRECISION
    ) internal pure returns (uint256 y) {
        uint256 c = (D * D) / (x * 2);
        c = (c * D) / ((N_A * 2) / A_PRECISION);
        uint256 b = x + ((D * A_PRECISION) / N_A);
        uint256 yPrev;
        y = D;
        // @dev Iterative approximation.
        for (uint256 i = 0; i < MAX_LOOP_LIMIT; i++) {
            yPrev = y;
            y = (y * y + c) / (y * 2 + b - D);
            if (y.within1(yPrev)) {
                break;
            }
        }
    }
}
