// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import { Math } from "@openzeppelin/utils/math/Math.sol";

library ConstantProductMath {
    using Math for uint256;

    uint256 public constant FEE_ACCURACY = 1_000_000; // 100%

    function getAmountOut(uint256 aAmountIn, uint256 aReserveIn, uint256 aReserveOut, uint256 aSwapFee)
        internal
        pure
        returns (uint256 rAmountOut)
    {
        require(aAmountIn > 0, "CP: INSUFFICIENT_INPUT_AMOUNT");
        require(aReserveIn > 0 && aReserveOut > 0, "CP: INSUFFICIENT_LIQUIDITY");

        uint256 lAmountInWithFee = aAmountIn.mulDiv(FEE_ACCURACY - aSwapFee, 1);
        uint256 lNumerator = lAmountInWithFee.mulDiv(aReserveOut, 1);
        uint256 lDenominator = aReserveIn.mulDiv(FEE_ACCURACY, 1) + lAmountInWithFee;
        rAmountOut = lNumerator / lDenominator;
    }

    function getAmountIn(uint256 aAmountOut, uint256 aReserveIn, uint256 aReserveOut, uint256 aSwapFee)
        internal
        pure
        returns (uint256 rAmountIn)
    {
        require(aAmountOut > 0, "CP: INSUFFICIENT_OUTPUT_AMOUNT");
        require(aReserveIn > 0 && aReserveOut > 0, "CP: INSUFFICIENT_LIQUIDITY");

        uint256 lNumerator = aReserveIn.mulDiv(aAmountOut, 1).mulDiv(FEE_ACCURACY, 1);
        uint256 lDenominator = (aReserveOut - aAmountOut).mulDiv(FEE_ACCURACY - aSwapFee, 1);
        rAmountIn = lNumerator / lDenominator + 1;
    }
}
