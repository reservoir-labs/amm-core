pragma solidity 0.8.13;

import "src/libraries/MathUtils.sol";

library StableMath {
    using MathUtils for uint256;

    /// @dev extra precision for intermediate calculations
    uint256 public constant A_PRECISION                 = 100;
    /// @dev minimum time to the ramp A
    uint256 public constant MIN_RAMP_TIME               = 1 days;
    /// @dev minimum amplification coefficient for the math to work
    uint256 public constant MIN_A                       = 1;
    /// @dev maximum amplification coefficient
    uint256 public constant MAX_A                       = 10_000;
    /// @dev maximum rate of change daily
    /// it is possible to change A by a factor of 8 over 3 days (2 ** 3)
    uint256 public constant MAX_AMP_UPDATE_DAILY_RATE   = 2;
    /// @dev required as an upper limit for iterative calculations not guaranteed to converge
    uint256 private constant MAX_LOOP_LIMIT             = 256;
    /// @dev 100% in basis points
    uint256 private constant MAX_FEE                    = 10_000;

    function _getAmountOut(
        uint256 amountIn,
        uint256 reserve0,
        uint256 reserve1,
        uint256 token0PrecisionMultiplier,
        uint256 token1PrecisionMultiplier,
        bool token0In,
        uint256 swapFee,
        uint256 N_A        // solhint-disable-line var-name-mixedcase
    ) internal pure returns(uint256 dy) {
    unchecked {
        uint256 adjustedReserve0 = reserve0 * token0PrecisionMultiplier;
        uint256 adjustedReserve1 = reserve1 * token1PrecisionMultiplier;
        uint256 feeDeductedAmountIn = amountIn - (amountIn * swapFee) / MAX_FEE;
        uint256 d = _computeLiquidityFromAdjustedBalances(adjustedReserve0, adjustedReserve1, N_A);

        if (token0In) {
            uint256 x = adjustedReserve0 + (feeDeductedAmountIn * token0PrecisionMultiplier);
            uint256 y = _getY(x, d, N_A);
            dy = adjustedReserve1 - y - 1;
            dy /= token1PrecisionMultiplier;
        } else {
            uint256 x = adjustedReserve1 + (feeDeductedAmountIn * token1PrecisionMultiplier);
            uint256 y = _getY(x, d, N_A);
            dy = adjustedReserve0 - y - 1;
            dy /= token0PrecisionMultiplier;
        }
    }
    }

    function _computeLiquidityFromAdjustedBalances(
        uint256 xp0,
        uint256 xp1,
        uint256 N_A        // solhint-disable-line var-name-mixedcase
    ) internal pure returns (uint256) {
        uint256 s = xp0 + xp1;

        if (s == 0) {
            return 0;
        }
        uint256 prevD;
        // solhint-disable-next-line var-name-mixedcase
        uint256 D = s;
        for (uint256 i = 0; i < MAX_LOOP_LIMIT; i++) {
            uint256 dP = (((D * D) / xp0) * D) / xp1 / 4;
            prevD = D;
            D = (((N_A * s) / A_PRECISION + 2 * dP) * D) / ((N_A - A_PRECISION) * D / A_PRECISION + 3 * dP);
            if (D.within1(prevD)) {
                return D;
            }
        }
        revert("SM: DID_NOT_CONVERGE");
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
        uint256 D,          // solhint-disable-line var-name-mixedcase
        uint256 N_A        // solhint-disable-line var-name-mixedcase
    ) internal pure returns (uint256 y) {
        uint256 c = (D * D) / (x * 2);
        c = (c * D) * A_PRECISION / (N_A * 2);
        uint256 b = x + ((D * A_PRECISION) / N_A);
        uint256 yPrev;
        y = D;
        // @dev Iterative approximation.
        for (uint256 i = 0; i < MAX_LOOP_LIMIT; i++) {
            yPrev = y;
            y = (y * y + c) / (y * 2 + b - D);
            if (y.within1(yPrev)) {
                return y;
            }
        }
        revert("SM: GETY_DID_NOT_CONVERGE");
    }
}
