pragma solidity ^0.8.0;

import "test/__fixtures/BaseTest.sol";

import { IPair } from "src/interfaces/IPair.sol";

contract PairTest is BaseTest
{
    IPair[] internal _pairs;
    IPair   internal _pair;

    function setUp() public
    {
        _pairs.push(_constantProductPair);
        _pairs.push(_stablePair);
    }

    modifier parameterizedTest() {
        for (uint256 i = 0; i < _pairs.length; ++i) {
            uint256 lBefore = vm.snapshot();
            _pair = _pairs[i];
            _;
            vm.revertTo(lBefore);
        }
    }

    function testCustomSwapFee_OffByDefault() public parameterizedTest
    {
        // assert
        assertEq(_pair.customSwapFee(), type(uint).max);
        assertEq(_pair.swapFee(), 3_000);
    }

    function testSetSwapFeeForPair() public parameterizedTest
    {
        // act
        _factory.rawCall(
            address(_pair),
            abi.encodeWithSignature("setCustomSwapFee(uint256)", 100),
            0
        );

        // assert
        assertEq(_pair.customSwapFee(), 100);
        assertEq(_pair.swapFee(), 100);
    }

    function testSetSwapFeeForPair_Reset() public parameterizedTest
    {
        // arrange
        _factory.rawCall(
            address(_pair),
            abi.encodeWithSignature("setCustomSwapFee(uint256)", 10_000),
            0
        );

        // act
        _factory.rawCall(
            address(_pair),
            abi.encodeWithSignature("setCustomSwapFee(uint256)", type(uint).max),
            0
        );

        // assert
        assertEq(_pair.customSwapFee(), type(uint).max);
        assertEq(_pair.swapFee(), 3_000);
    }

    function testSetSwapFeeForPair_BreachMaximum() public parameterizedTest
    {
        // act & assert
        vm.expectRevert("P: INVALID_SWAP_FEE");
        _factory.rawCall(
            address(_pair),
            abi.encodeWithSignature("setCustomSwapFee(uint256)", 400_000),
            0
        );
    }

    function testCustomPlatformFee_OffByDefault() public parameterizedTest
    {
        // assert
        assertEq(_pair.customPlatformFee(), type(uint).max);
        assertEq(_pair.platformFee(), 250_000);
    }

    function testSetPlatformFeeForPair() public parameterizedTest
    {
        // act
        _factory.rawCall(
            address(_pair),
            abi.encodeWithSignature("setCustomPlatformFee(uint256)", 10_000),
            0
        );

        // assert
        assertEq(_pair.customPlatformFee(), 10_000);
        assertEq(_pair.platformFee(), 10_000);
    }

    function testSetPlatformFeeForPair_Reset() public parameterizedTest
    {
        // arrange
        _factory.rawCall(
            address(_pair),
            abi.encodeWithSignature("setCustomPlatformFee(uint256)", 10_000),
            0
        );

        // act
        _factory.rawCall(
            address(_pair),
            abi.encodeWithSignature("setCustomPlatformFee(uint256)", type(uint).max),
            0
        );

        // assert
        assertEq(_pair.customPlatformFee(), type(uint).max);
        assertEq(_pair.platformFee(), 250_000);
    }

    function testSetPlatformFeeForPair_BreachMaximum(uint256 aPlatformFee) public parameterizedTest
    {
        // assume
        uint256 lPlatformFee = bound(aPlatformFee, _pair.MAX_PLATFORM_FEE() + 1, type(uint256).max);

        // act & assert
        vm.expectRevert("P: INVALID_PLATFORM_FEE");
        _factory.rawCall(
            address(_pair),
            abi.encodeWithSignature("setCustomPlatformFee(uint256)", lPlatformFee),
            0
        );
    }

    function testUpdateDefaultFees() public parameterizedTest
    {
        // arrange
        _factory.set(keccak256("ConstantProductPair::swapFee"), bytes32(uint256(200)));
        _factory.set(keccak256("ConstantProductPair::platformFee"), bytes32(uint256(5000)));

        // act
        _pair.updateSwapFee();
        _pair.updatePlatformFee();

        // assert
        assertEq(_pair.swapFee(), 200);
        assertEq(_pair.platformFee(), 5000);
    }

    function testRecoverToken() public parameterizedTest
    {
        // arrange
        uint256 lAmountToRecover = 1e18;
        _tokenC.mint(address(_pair), 1e18);

        // act
        _pair.recoverToken(address(_tokenC));

        // assert
        assertEq(_tokenC.balanceOf(address(_recoverer)), lAmountToRecover);
        assertEq(_tokenC.balanceOf(address(_pair)), 0);
    }
}
