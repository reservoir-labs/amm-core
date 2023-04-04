pragma solidity ^0.8.0;

import "forge-std/Test.sol";

contract StdMathTest is Test {
    function testPercentDelta() external {
        // arrange
        uint256 lA = 1e18;
        uint256 lB = 0.5e18;

        // act
        uint256 lDelta = stdMath.percentDelta(lA, lB);

        // assert
        assertEq(lDelta, 1e18);
    }

    function testPercentDelta_PlusOne() external {
        // arrange
        uint256 lA = 1e18 + 1;
        uint256 lB = 0.5e18;

        // act
        uint256 lDelta = stdMath.percentDelta(lA, lB);

        // assert
        assertEq(lDelta, 1_000_000_000_000_000_002);
    }

    function testPercentDelta_MinusOne() external {
        // arrange
        uint256 lA = 1e18 - 1;
        uint256 lB = 0.5e18;

        // act
        uint256 lDelta = stdMath.percentDelta(lA, lB);

        // assert
        assertEq(lDelta, 999_999_999_999_999_998);
    }

    function testToLowRes() external {
        int res = LogCompression.toLowResLog(1);
        int res1 = LogCompression.toLowResLog(1000);
        int res2 = LogCompression.toLowResLog(type(uint256).max / 2 - 10);
        console.logInt(res);
        console.logInt(res1);
        console.logInt(res2);
    }
}
