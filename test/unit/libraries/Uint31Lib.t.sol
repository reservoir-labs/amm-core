// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import { Uint31Lib } from "src/libraries/Uint31Lib.sol";

contract Uint31LibTest is Test {


    function testSubtract() external {
        uint32 lA = 4;
        uint32 lB = 0x7FFFFFFF; // max value of uint31

        uint32 lResult = Uint31Lib.subtract(lA, lB);

        console.log(lA);
        console.log(lB);
        console.log(lResult);

        assertEq(lResult, 5);
    }
}
