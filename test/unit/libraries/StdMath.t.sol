pragma solidity ^0.8.0;

import "forge-std/Test.sol";

contract StdMathTest is Test {
    function testPercentDelta() external {
        // arrange
        uint lA = 1e18;
        uint lB = 0.5e18;

        // act
        uint lDelta = stdMath.percentDelta(lA, lB);

        // assert
        assertEq(lDelta, 1e18);
    }

    function testPercentDelta_PlusOne() external {
        // arrange
        uint lA = 1e18 + 1;
        uint lB = 0.5e18;

        // act
        uint lDelta = stdMath.percentDelta(lA, lB);

        // assert
        assertEq(lDelta, 1_000_000_000_000_000_002);
    }

    function testPercentDelta_MinusOne() external {
        // arrange
        uint lA = 1e18 - 1;
        uint lB = 0.5e18;

        // act
        uint lDelta = stdMath.percentDelta(lA, lB);

        // assert
        assertEq(lDelta, 999_999_999_999_999_998);
    }
}
