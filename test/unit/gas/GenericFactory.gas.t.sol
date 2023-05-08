// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "test/__fixtures/BaseTest.sol";

contract GenericFactoryGasTest is BaseTest {
    function testCreateFactory() external {
        new GenericFactory();
    }

    function testCreateConstantProductPair() external {
        _factory.createPair(IERC20(address(_tokenC)), IERC20(address(_tokenD)), 0);
    }

    function testCreateStablePair() external {
        _factory.createPair(IERC20(address(_tokenC)), IERC20(address(_tokenD)), 1);
    }
}
