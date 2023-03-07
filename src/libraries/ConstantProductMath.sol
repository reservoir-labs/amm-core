// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

library ConstantProductMath {
    uint256 public constant FEE_ACCURACY = 1_000_000; // 100%

    function getAmountOut(uint256 aAmountIn, uint256 aReserveIn, uint256 aReserveOut, uint256 aSwapFee)
        internal
        pure
        returns (uint256 rAmountOut)
    {
        require(aAmountIn > 0, "CP: INSUFFICIENT_INPUT_AMOUNT");
        require(aReserveIn > 0 && aReserveOut > 0, "CP: INSUFFICIENT_LIQUIDITY");

        uint256 lAmountInWithFee = aAmountIn * (FEE_ACCURACY - aSwapFee);
        uint256 lNumerator = lAmountInWithFee * aReserveOut;
        uint256 lDenominator = aReserveIn * FEE_ACCURACY + lAmountInWithFee;
        rAmountOut = lNumerator / lDenominator;
    }

    function getAmountIn(uint256 aAmountOut, uint256 aReserveIn, uint256 aReserveOut, uint256 aSwapFee)
        internal
        pure
        returns (uint256 rAmountIn)
    {
        require(aAmountOut > 0, "CP: INSUFFICIENT_OUTPUT_AMOUNT");
        require(aReserveIn > 0 && aReserveOut > 0, "CP: INSUFFICIENT_LIQUIDITY");

        uint256 lNumerator = aReserveIn * aAmountOut * FEE_ACCURACY;
        uint256 lDenominator = (aReserveOut - aAmountOut) * (FEE_ACCURACY - aSwapFee);
        rAmountIn = lNumerator / lDenominator + 1;
    }
}
