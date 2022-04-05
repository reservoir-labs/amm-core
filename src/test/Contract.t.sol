// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.5.16;

import "ds-test/test.sol";

import { UniswapV2Factory } from "src/UniswapV2Factory.sol";

contract ContractTest is DSTest {
    function setUp() public {}

    function testExample() public {
        UniswapV2Factory lFactory = new UniswapV2Factory();
        assertTrue(true);
    }
}
