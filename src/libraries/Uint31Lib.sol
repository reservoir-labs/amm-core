// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

// arithmetic for uint31 functions as the timestamp we have stored in our is limited to 31 bits
// 1 bit is for storing the reentrancy lock variable
library Uint31Lib {
    // subtracts b from a
    // wraps around for underflow
    function sub(uint32 a, uint32 b) internal pure returns (uint32 rResult) {
        require(a < 0x80000000, "a exceeds uint31");
        require(b < 0x80000000, "b exceeds uint31");

        unchecked {
            rResult = a - b;
        }
        rResult &= 0x7FFFFFFF;
    }
}
