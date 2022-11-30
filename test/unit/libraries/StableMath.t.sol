pragma solidity ^0.8.0;

import "test/__fixtures/BaseTest.sol";

import { StableMath } from "src/libraries/StableMath.sol";
import { Math } from "@openzeppelin/utils/math/Math.sol";

contract StableMathTest is BaseTest {
    function testMinALessThanMaxA() public {
        // assert
        assertLt(StableMath.MIN_A, StableMath.MAX_A);
    }

    function testComputeLiquidityFromAdjustedBalances_ConvergeEvenWithVeryUnbalancedValues(
        uint aReserve0,
        uint aReserve1,
        uint aN_A
    ) public {
        // assume - covers ratios up to 1:10000000000, which is good enough even in the case of a depeg
        uint lReserve0 = bound(aReserve0, 1e18, type(uint112).max / 100);
        uint lReserve1 = bound(aReserve1, lReserve0 / 1e10, Math.min(type(uint112).max / 100, lReserve0 * 1e10));
        uint lN_A =
            2 * bound(aN_A, StableMath.MIN_A * StableMath.A_PRECISION, StableMath.MAX_A * StableMath.A_PRECISION);

        // act
        uint lLiq = StableMath._computeLiquidityFromAdjustedBalances(lReserve0, lReserve1, lN_A);

        // assert
        assertLe(lLiq, lReserve0 + lReserve1);
    }

    function testGetAmountOut(uint aAmtIn, uint aSwapFee, uint aAmp) public {
        // assume
        uint lReserve0 = 120_000_000e18;
        uint lReserve1 = 11_000_000e6;
        uint lAmtIn = bound(aAmtIn, 1, lReserve0 / 1e12);
        uint lSwapFee = bound(aSwapFee, 0, _stablePair.MAX_SWAP_FEE());
        uint lN_A =
            2 * bound(aAmp, StableMath.MIN_A * StableMath.A_PRECISION, StableMath.MAX_A * StableMath.A_PRECISION);

        // act
        uint lAmtOut = StableMath._getAmountOut(lAmtIn, lReserve0, lReserve1, 1, 1e12, false, lSwapFee, lN_A);

        // assert
        uint lAmtInAfterSwapFee = lAmtIn * (_stablePair.FEE_ACCURACY() - lSwapFee) / _stablePair.FEE_ACCURACY();
        assertGe(lAmtOut, lAmtInAfterSwapFee);
    }

    function testGetAmountIn(uint aAmtOut, uint aSwapFee, uint aAmp) public {
        // assume
        uint lReserve0 = 11_000_000e6;
        uint lReserve1 = 120_000_000e18;
        uint lAmtOut = bound(aAmtOut, 1, lReserve0 / 2);
        uint lSwapFee = bound(aSwapFee, 0, _stablePair.MAX_SWAP_FEE());
        uint lN_A =
            2 * bound(aAmp, StableMath.MIN_A * StableMath.A_PRECISION, StableMath.MAX_A * StableMath.A_PRECISION);

        // act
        uint lAmtIn = StableMath._getAmountIn(lAmtOut, lReserve0, lReserve1, 1e12, 1, true, lSwapFee, lN_A);

        // assert
        assertGe(lAmtIn / 1e12, lAmtOut);
    }
}
