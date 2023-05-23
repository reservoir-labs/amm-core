// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import { MathWrapper } from "test/__mocks/MathWrapper.sol";

contract FixedPointMathLibTest is Test {
    MathWrapper private _wrapper = new MathWrapper();

    function testMulDiv(uint256 aNumerator1, uint256 aNumerator2, uint256 aDenominator) external {
        try _wrapper.soladyMulDiv(aNumerator1, aNumerator2, aDenominator) returns (uint256 lSoladyResult) {
            uint256 lSolmateResult = _wrapper.solmateMulDiv(aNumerator1, aNumerator2, aDenominator);
            assertEq(lSoladyResult, lSolmateResult);
        } catch {
            vm.expectRevert();
            _wrapper.solmateMulDiv(aNumerator1, aNumerator2, aDenominator);
        }
    }

    function testFullMulDiv(uint256 aNumerator1, uint256 aNumerator2, uint256 aDenominator) external {
        try _wrapper.soladyFullMulDiv(aNumerator1, aNumerator2, aDenominator) returns (uint256 lSoladyResult) {
            uint256 lOZResult = _wrapper.ozFullMulDiv(aNumerator1, aNumerator2, aDenominator);
            assertEq(lSoladyResult, lOZResult);
        } catch {
            vm.expectRevert();
            _wrapper.ozFullMulDiv(aNumerator1, aNumerator2, aDenominator);
        }
    }
}
