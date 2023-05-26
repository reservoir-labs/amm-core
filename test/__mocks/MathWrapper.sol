// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { FixedPointMathLib as solady } from "solady/utils/FixedPointMathLib.sol";
import { FixedPointMathLib as solmate } from "solmate/utils/FixedPointMathLib.sol";
import { Math as oz } from "@openzeppelin/utils/math/Math.sol";

contract MathWrapper {
    function solmateMulDiv(uint256 x, uint256 y, uint256 denominator) external pure returns (uint256 result) {
        return solmate.mulDivDown(x, y, denominator);
    }

    function soladyMulDiv(uint256 x, uint256 y, uint256 denominator) external pure returns (uint256 result) {
        return solady.mulDiv(x, y, denominator);
    }

    function soladyFullMulDiv(uint256 x, uint256 y, uint256 denominator) external pure returns (uint256 result) {
        return solady.fullMulDiv(x, y, denominator);
    }

    function ozFullMulDiv(uint256 x, uint256 y, uint256 denominator) external pure returns (uint256 result) {
        return oz.mulDiv(x, y, denominator);
    }
}
