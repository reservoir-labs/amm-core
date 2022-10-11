pragma solidity 0.8.13;

import "test/__fixtures/BaseTest.sol";

import "test/__fixtures/MintableERC20.sol";

import { ConstantProductPair } from "src/curve/constant-product/ConstantProductPair.sol";
import { StablePair } from "src/curve/stable/StablePair.sol";
import { GenericFactory } from "src/GenericFactory.sol";

contract GenericFactoryTest is BaseTest
{
    function testCreatePair_AllCurves(uint256 aCurveId) public
    {
        // assume
        uint256 lCurveId = bound(aCurveId, 0, 1);

        // act
        address lPair = _factory.createPair(address(_tokenA), address(_tokenC), lCurveId);

        // assert
        assertEq(_factory.getPair(address(_tokenA), address(_tokenC), lCurveId), address(lPair));
    }

    function testCreatePair_MoreThan18Decimals(uint256 aCurveId) public
    {
        // assume
        uint256 lCurveId = bound(aCurveId, 0, 1);

        // act & assert
        vm.expectRevert("FACTORY: DEPLOY_FAILED");
        _createPair(address(_tokenE), address(_tokenA), lCurveId);
    }
}
