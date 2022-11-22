pragma solidity 0.8.13;

import "test/__fixtures/BaseTest.sol";

import "test/__fixtures/MintableERC20.sol";

//import { ConstantProductPair } from "src/curve/constant-product/ConstantProductPair.sol";
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

    function testCreatePair_ZeroAddress(uint256 aCurveId) public
    {
        // assume
        uint256 lCurveId = bound(aCurveId, 0, 1);

        // act & assert
        vm.expectRevert("FACTORY: ZERO_ADDRESS");
        _createPair(address(0), address(_tokenA), lCurveId);
    }

    function testCreatePair_CurveDoesNotExist(uint256 aCurveId) public
    {
        // assume
        uint256 lCurveId = bound(aCurveId, 2, type(uint256).max);

        // act & assert
        vm.expectRevert(stdError.indexOOBError);
        _createPair(address(_tokenB), address(_tokenD), lCurveId);
    }

    function testCreatePair_IdenticalAddress(uint256 aCurveId) public
    {
        // assume
        uint256 lCurveId = bound(aCurveId, 0, 1);

        // act & assert
        vm.expectRevert("FACTORY: IDENTICAL_ADDRESSES");
        _createPair(address(_tokenD), address(_tokenD), lCurveId);
    }

    function testCreatePair_PairAlreadyExists(uint256 aCurveId) public
    {
        // assume
        uint256 lCurveId = bound(aCurveId, 0, 1);

        // act & assert
        vm.expectRevert("FACTORY: PAIR_EXISTS");
        _createPair(address(_tokenA), address(_tokenB), lCurveId);
    }

    function testAllPairs() public
    {
        // arrange
        address lPair3 = _factory.createPair(address(_tokenA), address(_tokenC), 0);
        address lPair4 = _factory.createPair(address(_tokenA), address(_tokenC), 1);

        // act
        address[] memory lAllPairs = _factory.allPairs();

        // assert
        assertEq(lAllPairs.length, 4);
//        assertEq(lAllPairs[0], address(_constantProductPair));
        assertEq(lAllPairs[1], address(_stablePair));
        assertEq(lAllPairs[2], lPair3);
        assertEq(lAllPairs[3], lPair4);
    }

    function testAddCurve() public
    {
        // arrange
        bytes memory lInitCode = bytes("dummy bytes");

        // act
        uint256 lNewCurveId = _factory.addCurve(lInitCode);

        // assert
        assertEq(lNewCurveId, 2);
    }

    function testAddCurve_OnlyOwner() public
    {
        // arrange
        vm.prank(_alice);

        // act & assert
        vm.expectRevert("Ownable: caller is not the owner");
        _factory.addCurve(bytes("random bytes"));
    }

    function testGetPair() public
    {
        // assert - ensure double mapped
//        assertEq(_factory.getPair(address(_tokenA), address(_tokenB), 0), address(_constantProductPair));
//        assertEq(_factory.getPair(address(_tokenB), address(_tokenA), 0), address(_constantProductPair));
    }
}
