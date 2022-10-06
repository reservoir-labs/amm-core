pragma solidity ^0.8.0;

import "test/__fixtures/BaseTest.sol";

contract PairTest is BaseTest
{
    function testCustomSwapFee_OffByDefault() public
    {
        // assert
        assertEq(_constantProductPair.customSwapFee(), type(uint).max);
        assertEq(_constantProductPair.swapFee(), 3_000);
    }

    function testSetSwapFeeForPair() public
    {
        // act
        _factory.rawCall(
            address(_constantProductPair),
            abi.encodeWithSignature("setCustomSwapFee(uint256)", 100),
            0
        );

        // assert
        assertEq(_constantProductPair.customSwapFee(), 100);
        assertEq(_constantProductPair.swapFee(), 100);
    }

    function testSetSwapFeeForPair_Reset() public
    {
        // arrange
        _factory.rawCall(
            address(_constantProductPair),
            abi.encodeWithSignature("setCustomSwapFee(uint256)", 10_000),
            0
        );

        // act
        _factory.rawCall(
            address(_constantProductPair),
            abi.encodeWithSignature("setCustomSwapFee(uint256)", type(uint).max),
            0
        );

        // assert
        assertEq(_constantProductPair.customSwapFee(), type(uint).max);
        assertEq(_constantProductPair.swapFee(), 3_000);
    }

    function testSetSwapFeeForPair_BreachMaximum() public
    {
        // act & assert
        vm.expectRevert("P: INVALID_SWAP_FEE");
        _factory.rawCall(
            address(_constantProductPair),
            abi.encodeWithSignature("setCustomSwapFee(uint256)", 400_000),
            0
        );
    }

    function testCustomPlatformFee_OffByDefault() public
    {
        // assert
        assertEq(_constantProductPair.customPlatformFee(), type(uint).max);
        assertEq(_constantProductPair.platformFee(), 250_000);
    }

    function testSetPlatformFeeForPair() public
    {
        // act
        _factory.rawCall(
            address(_constantProductPair),
            abi.encodeWithSignature("setCustomPlatformFee(uint256)", 10_000),
            0
        );

        // assert
        assertEq(_constantProductPair.customPlatformFee(), 10_000);
        assertEq(_constantProductPair.platformFee(), 10_000);
    }

    function testSetPlatformFeeForPair_Reset() public
    {
        // arrange
        _factory.rawCall(
            address(_constantProductPair),
            abi.encodeWithSignature("setCustomPlatformFee(uint256)", 10_000),
            0
        );

        // act
        _factory.rawCall(
            address(_constantProductPair),
            abi.encodeWithSignature("setCustomPlatformFee(uint256)", type(uint).max),
            0
        );

        // assert
        assertEq(_constantProductPair.customPlatformFee(), type(uint).max);
        assertEq(_constantProductPair.platformFee(), 250_000);
    }

    function testSetPlatformFeeForPair_BreachMaximum(uint256 aPlatformFee) public
    {
        // assume
        uint256 lPlatformFee = bound(aPlatformFee, _constantProductPair.MAX_PLATFORM_FEE() + 1, type(uint256).max);

        // act & assert
        vm.expectRevert("P: INVALID_PLATFORM_FEE");
        _factory.rawCall(
            address(_constantProductPair),
            abi.encodeWithSignature("setCustomPlatformFee(uint256)", lPlatformFee),
            0
        );
    }

    function testUpdateDefaultFees() public
    {
        // arrange
        _factory.set(keccak256("ConstantProductPair::swapFee"), bytes32(uint256(200)));
        _factory.set(keccak256("ConstantProductPair::platformFee"), bytes32(uint256(5000)));

        // act
        _constantProductPair.updateSwapFee();
        _constantProductPair.updatePlatformFee();

        // assert
        assertEq(_constantProductPair.swapFee(), 200);
        assertEq(_constantProductPair.platformFee(), 5000);
    }

    function testRecoverToken() public
    {
        // arrange
        uint256 lAmountToRecover = 1e18;
        _tokenC.mint(address(_stablePair), 1e18);

        // act
        _stablePair.recoverToken(address(_tokenC));

        // assert
        assertEq(_tokenC.balanceOf(address(_recoverer)), lAmountToRecover);
        assertEq(_tokenC.balanceOf(address(_stablePair)), 0);
    }
}
