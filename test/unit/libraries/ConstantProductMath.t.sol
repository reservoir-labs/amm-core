pragma solidity 0.8.13;

import "test/__fixtures/BaseTest.sol";

import { ConstantProductOracleMath } from "src/libraries/ConstantProductOracleMath.sol";
import { LogCompression } from "src/libraries/LogCompression.sol";

contract ConstantProductMathTest is BaseTest
{
//    function testConstantProductOracleMath() external
//    {
//        // assert
//        assertEq(ConstantProductOracleMath.calcLogPrice(1e18, 1e18), LogCompression.toLowResLog(1e18));
//        assertEq(
//            ConstantProductOracleMath.calcLogPrice(type(uint112).max, type(uint112).max),
//            LogCompression.toLowResLog(1e18)
//        );
//        assertEq(
//            ConstantProductOracleMath.calcLogPrice(type(uint112).max / 2, type(uint112).max),
//            LogCompression.toLowResLog(2e18)
//        );
//        assertEq(
//            ConstantProductOracleMath.calcLogPrice(type(uint112).max, type(uint112).max / 2),
//            LogCompression.toLowResLog(0.5e18)
//        );
//        assertEq(
//            ConstantProductOracleMath.calcLogPrice(type(uint112).max / 10, type(uint112).max),
//            LogCompression.toLowResLog(10e18)
//        );
//        assertEq(
//            ConstantProductOracleMath.calcLogPrice(type(uint112).max, type(uint112).max / 10),
//            LogCompression.toLowResLog(0.1e18)
//        );
//
//        assertApproxEqRel(
//            ConstantProductOracleMath.calcLogPrice(type(uint112).max, type(uint112).max / 1e17),
//            LogCompression.toLowResLog(1e18 / 1e17),
//            // we are chopping off information from the reserves when we scale them by a non power of 2
//            0.01e18
//        );
//        assertApproxEqRel(
//            ConstantProductOracleMath.calcLogPrice(type(uint112).max / 1e17, type(uint112).max),
//            LogCompression.toLowResLog(1e18 * 1e17),
//            // we are chopping off information from the reserves when we scale them by a non power of 2
//            0.01e18
//        );
//        assertApproxEqRel(
//            ConstantProductOracleMath.calcLogPrice(type(uint112).max, type(uint112).max / 1e18),
//            LogCompression.toLowResLog(1e18 / 1e18),
//            0.1e18
//        );
//        assertApproxEqRel(
//            ConstantProductOracleMath.calcLogPrice(type(uint112).max / 1e18, type(uint112).max),
//            LogCompression.toLowResLog(1e18 * 1e18),
//            0.1e18
//        );
//    }

    function testCalcLogPrice_ReturnsOneWeiWhenPriceDiffGreaterThan1e18(uint256 aReserve0, uint256 aReserve1) public
    {
        // arrange
        uint256 lReserve1 = bound(aReserve0, 1, type(uint112).max / 1e18);
        uint256 lReserve0 = bound(aReserve1, lReserve1 * 1e18, type(uint112).max);

        // act
        (, int112 lLogPrice) = ConstantProductOracleMath.calcLogPrice(lReserve0, lReserve1);

        // assert
        assertEq(lLogPrice, LogCompression.toLowResLog(1));
    }
}
