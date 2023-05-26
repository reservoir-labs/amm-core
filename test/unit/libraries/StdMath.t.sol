pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import { StdMath } from "src/libraries/StdMath.sol";

contract StdMathTest is Test {
    using StdMath for uint256;

    function testPercentDelta() external {
        // arrange
        uint256 lA = 1e18;
        uint256 lB = 0.5e18;

        // act
        uint256 lDelta = lA.percentDelta(lB);

        // assert
        assertEq(lDelta, 1e18);
    }

    function testPercentDelta_PlusOne() external {
        // arrange
        uint256 lA = 1e18 + 1;
        uint256 lB = 0.5e18;

        // act
        uint256 lDelta = lA.percentDelta(lB);

        // assert
        assertEq(lDelta, 1_000_000_000_000_000_002);
    }

    function testPercentDelta_MinusOne() external {
        // arrange
        uint256 lA = 1e18 - 1;
        uint256 lB = 0.5e18;

        // act
        uint256 lDelta = lA.percentDelta(lB);

        // assert
        assertEq(lDelta, 999_999_999_999_999_998);
    }
}
