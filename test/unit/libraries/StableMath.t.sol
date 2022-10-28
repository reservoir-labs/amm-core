pragma solidity ^0.8.0;

import "test/__fixtures/BaseTest.sol";

import { StableMath } from "src/libraries/StableMath.sol";
import { Math } from "@openzeppelin/utils/math/Math.sol";

contract StableMathTest is BaseTest {

    function testMinALessThanMaxA() public
    {
        // assert
        assertLt(StableMath.MIN_A, StableMath.MAX_A);
    }

    function testComputeLiquidityFromAdjustedBalances_ConvergeEvenWithVeryUnbalancedValues (
        uint256 aReserve0, uint256 aReserve1, uint256 aN_A
    ) public
    {
        // assume - covers ratios up to 1:1000, which is good enough even in the case of a depeg
        uint256 lReserve0 = bound(aReserve0, 1e18, type(uint112).max / 100);
        uint256 lReserve1 = bound(aReserve1, lReserve0 / 1e10, Math.min(type(uint112).max / 100, lReserve0 * 1e10));
        uint256 lN_A = 2 * bound(aN_A, StableMath.MIN_A * StableMath.A_PRECISION, StableMath.MAX_A * StableMath.A_PRECISION);

        // act
        uint256 lLiq = StableMath._computeLiquidityFromAdjustedBalances(lReserve0, lReserve1, lN_A);

        // assert
        assertLe(lLiq, lReserve0 + lReserve1);
    }

    function testGetAmountOut(uint256 aAmtIn, uint256 aSwapFee, uint256 aAmp) public
    {
        // assume
        uint256 lAmtIn = bound(aAmtIn, 1, type(uint112).max / 2);
        uint256 lSwapFee = bound(aSwapFee, 0, _stablePair.MAX_SWAP_FEE());
        uint256 lN_A = 2 * bound(aAmp, StableMath.MIN_A * StableMath.A_PRECISION, StableMath.MAX_A * StableMath.A_PRECISION);

        // arrange
        uint256 lReserve0 = 120_000_000e18;
        uint256 lReserve1 = 11_000_000e6;

        // act
        uint256 lAmtOut = StableMath._getAmountOut(lAmtIn, lReserve0, lReserve1, 1, 1e12, false, lSwapFee, lN_A);

        // assert - what to assert?
    }

    function testGetAmountIn(uint256 aAmtOut, uint256 aSwapFee, uint256 aAmp) public
    {
        // assume
        uint256 lReserve0 = 11_000_000e6;
        uint256 lReserve1 = 120_000_000e18;
        uint256 lAmtOut = bound(aAmtOut, 1, lReserve0 / 2);
        uint256 lSwapFee = bound(aSwapFee, 0, _stablePair.MAX_SWAP_FEE());
        uint256 lN_A = 2 * bound(aAmp, StableMath.MIN_A * StableMath.A_PRECISION, StableMath.MAX_A * StableMath.A_PRECISION);

        // act
        uint256 lAmtIn = StableMath._getAmountIn(lAmtOut, lReserve0, lReserve1, 1e12, 1, true, lSwapFee, lN_A);

        // assert
        assertGe(lAmtIn / 1e12, lAmtOut);
    }
}
