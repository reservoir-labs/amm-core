pragma solidity =0.8.13;

import "forge-std/Test.sol";

import "test/__fixtures/MintableERC20.sol";

import { GenericFactory } from "src/GenericFactory.sol";
import { UniswapV2Pair } from "src/curve/constant-product/UniswapV2Pair.sol";

contract PairTest is Test
{
    address private mOwner = address(1);
    address private mRecoverer = address(3);

    MintableERC20 private mTokenA = new MintableERC20("TokenA", "TA");
    MintableERC20 private mTokenB = new MintableERC20("TokenB", "TB");

    GenericFactory private mFactory;

    function setUp() public
    {
        mFactory = new GenericFactory();

        mFactory.addCurve(type(UniswapV2Pair).creationCode);
        mFactory.set(keccak256("UniswapV2Pair::swapFee"), bytes32(uint256(30)));
        mFactory.set(keccak256("UniswapV2Pair::platformFee"), bytes32(uint256(2500)));
    }

    function createPair() private returns (address rPairAddress)
    {
        rPairAddress = mFactory.createPair(address(mTokenA), address(mTokenB), 0);
    }

    function testCustomSwapFeeOffByDefault() public
    {
        // arrange
        address pairAddress = createPair();

        // assert
        assertEq(UniswapV2Pair(pairAddress).customSwapFee(), 0);
        assertEq(UniswapV2Pair(pairAddress).swapFee(), 30);
    }

    function testSetCustomSwapFeeBasic() public
    {
        // arrange
        address pairAddress = createPair();

        // act
        mFactory.rawCall(
            pairAddress,
            abi.encodeWithSignature("setCustomSwapFee(uint256)", 100),
            0
        );

        // assert
        assertEq(UniswapV2Pair(pairAddress).customSwapFee(), 100);
        assertEq(UniswapV2Pair(pairAddress).swapFee(), 100);
    }

    function testSetCustomSwapFeeOnThenOff() public
    {
        // arrange
        address pairAddress = createPair();
        mFactory.rawCall(
            pairAddress,
            abi.encodeWithSignature("setCustomSwapFee(uint256)", 100),
            0
        );

        // act
        mFactory.rawCall(
            pairAddress,
            abi.encodeWithSignature("setCustomSwapFee(uint256)", 0),
            0
        );

        // assert
        assertEq(UniswapV2Pair(pairAddress).customSwapFee(), 0);
        assertEq(UniswapV2Pair(pairAddress).swapFee(), 30);
    }

    function testSetCustomSwapFeeMoreThanMaxSwapFee() public
    {
        // arrange
        address pairAddress = createPair();

        // act & assert
        vm.expectRevert("UniswapV2: INVALID_SWAP_FEE");
        mFactory.rawCall(
            pairAddress,
            abi.encodeWithSignature("setCustomSwapFee(uint256)", 4000),
            0
        );
    }

    function testCustomPlatformFeeOffByDefault() public
    {
        // arrange
        address pairAddress = createPair();

        // assert
        assertEq(UniswapV2Pair(pairAddress).customPlatformFee(), 0);
        assertEq(UniswapV2Pair(pairAddress).platformFee(), 2500);
    }

    function testSetCustomPlatformFeeBasic() public
    {
        // arrange
        address pairAddress = createPair();

        // act
        mFactory.rawCall(
            pairAddress,
            abi.encodeWithSignature("setCustomPlatformFee(uint256)", 100),
            0
        );

        // assert
        assertEq(UniswapV2Pair(pairAddress).customPlatformFee(), 100);
        assertEq(UniswapV2Pair(pairAddress).platformFee(), 100);
    }

    function testSetCustomPlatformFeeOnThenOff() public
    {
        // arrange
        address pairAddress = createPair();
        mFactory.rawCall(
            pairAddress,
            abi.encodeWithSignature("setCustomPlatformFee(uint256)", 100),
            0
        );

        // act
        mFactory.rawCall(
            pairAddress,
            abi.encodeWithSignature("setCustomPlatformFee(uint256)", 0),
            0
        );

        // assert
        assertEq(UniswapV2Pair(pairAddress).customPlatformFee(), 0);
        assertEq(UniswapV2Pair(pairAddress).platformFee(), 2500);
    }

    function testSetCustomPlatformFeeMoreThanMaxPlatformFee() public
    {
        // arrange
        address pairAddress = createPair();

        // act & assert
        vm.expectRevert("UniswapV2: INVALID_PLATFORM_FEE");
        mFactory.rawCall(
            pairAddress,
            abi.encodeWithSignature("setCustomPlatformFee(uint256)", 9000),
            0
        );
    }

    function testUpdateDefaultFees() public
    {
        // arrange
        address pairAddress = createPair();

        // act
        mFactory.set(keccak256("UniswapV2Pair::swapFee"), bytes32(uint256(200)));
        mFactory.set(keccak256("UniswapV2Pair::platformFee"), bytes32(uint256(5000)));

        UniswapV2Pair(pairAddress).updateSwapFee();
        UniswapV2Pair(pairAddress).updatePlatformFee();

        // assert
        assertEq(UniswapV2Pair(pairAddress).swapFee(), 200);
        assertEq(UniswapV2Pair(pairAddress).platformFee(), 5000);
    }
}
