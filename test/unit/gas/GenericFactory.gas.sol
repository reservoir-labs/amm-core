// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "test/__fixtures/BaseTest.sol";

contract GenericFactoryGasTest is BaseTest {
    function testCreateConstantProductPair() external {
        _factory.createPair(address(_tokenC), address(_tokenD), 0);
    }

    function testCreateStablePair() external {
        _factory.createPair(address(_tokenC), address(_tokenD), 1);
    }
}
