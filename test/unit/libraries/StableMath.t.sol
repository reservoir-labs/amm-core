pragma solidity 0.8.13;

import "forge-std/Test.sol";

import "src/libraries/StableMath.sol";

contract StableMathTest is Test {

    // todo: make into fuzz test
    // this test demonstrates that, given different values of A, the percentage growth between
    // two liquidity states remain the same, which is what we expect
    function testPercentageGrowth() public
    {
        // arrange
        uint256 lReserve0_t0 = 0.5e20;
        uint256 lReserve1_t0 = 1e20;
        uint256 lReserve0_t1 = 1e20;
        uint256 lReserve1_t1 = 2e20;
        uint256 A = 10000; // A = 100 with 100 as precision
        uint256 A2 = 20000;

        // act
        uint256 D0 = StableMath._computeLiquidityFromAdjustedBalances(lReserve0_t0, lReserve1_t0, 2 * A);
        console.log("D0", D0);
        uint256 D1 = StableMath._computeLiquidityFromAdjustedBalances(lReserve0_t1, lReserve1_t1, 2 * A);
        console.log("D1", D1);

        uint256 lPercentageGrowth1 = (D1 - D0) * 1e18 / D0;
        console.log(lPercentageGrowth1);

        uint256 D2 = StableMath._computeLiquidityFromAdjustedBalances(lReserve0_t0, lReserve1_t0, 2 * A2);
        console.log("D2", D2);
        uint256 D3 = StableMath._computeLiquidityFromAdjustedBalances(lReserve0_t1, lReserve1_t1, 2 * A2);
        console.log("D3", D3);

        uint256 lPercentageGrowth2 = (D3 - D2) * 1e18 / D2;
        console.log(lPercentageGrowth2);

        // assert
        assertEq(lPercentageGrowth1, lPercentageGrowth2);
        assertEq(lPercentageGrowth1, 1e18);
    }
}
