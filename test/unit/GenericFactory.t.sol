pragma solidity 0.8.13;

import "test/__fixtures/BaseTest.sol";

import "test/__fixtures/MintableERC20.sol";

import { ConstantProductPair } from "src/curve/constant-product/ConstantProductPair.sol";
import { StablePair } from "src/curve/stable/StablePair.sol";
import { GenericFactory } from "src/GenericFactory.sol";

contract GenericFactoryTest is BaseTest
{
    function testCreatePair_ConstantProduct() public
    {
        // act
        address lPair = _factory.createPair(address(_tokenA), address(_tokenC), 0);

        // assert
        assertEq(_factory.getPair(address(_tokenA), address(_tokenC), 0), address(lPair));
    }

    // todo: test creating the StablePair
}
