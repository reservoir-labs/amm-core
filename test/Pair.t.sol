pragma solidity =0.8.13;

import "forge-std/Test.sol";

import "test/__fixtures/MintableERC20.sol";

import "src/UniswapV2Factory.sol";
import "src/curve/constant-product/UniswapV2Pair.sol";

contract PairTest is Test
{
    address private mOwner = address(1);
    address private mRecoverer = address(3);

    MintableERC20 private mTokenA = new MintableERC20("TokenA", "TA");
    MintableERC20 private mTokenB = new MintableERC20("TokenB", "TB");

    UniswapV2Factory private mFactory;
    UniswapV2Pair private mPair;

    function setUp() public
    {
        mFactory = new UniswapV2Factory(30, 2500, mOwner, mRecoverer);
        createPair();
    }

    function createPair() private
    {
        mPair = UniswapV2Pair(mFactory.createPair(address(mTokenA), address(mTokenB)));
    }

    function testCustomSwapFeeOffByDefault() public
    {
        // assert
        assertEq(mPair.customSwapFee(), 0);
        assertEq(mPair.swapFee(), 30);
    }

    function testSetCustomSwapFeeBasic() public
    {
        // act
        mFactory.setSwapFeeForPair(address(mPair), 100);

        // assert
        assertEq(mPair.customSwapFee(), 100);
        assertEq(mPair.swapFee(), 100);
    }

    function testSetCustomSwapFeeOnThenOff() public
    {
        // arrange
        mFactory.setSwapFeeForPair(address(mPair), 100);

        // act
        mFactory.setSwapFeeForPair(address(mPair), 0);

        // assert
        assertEq(mPair.customSwapFee(), 0);
        assertEq(mPair.swapFee(), 30);
    }

    function testSetCustomSwapFeeMoreThanMaxSwapFee() public
    {
        // act & assert
        vm.expectRevert("UniswapV2: INVALID_SWAP_FEE");
        mFactory.setSwapFeeForPair(address(mPair), 4000);
    }

    function testCustomPlatformFeeOffByDefault() public
    {
        // assert
        assertEq(mPair.customPlatformFee(), 0);
        assertEq(mPair.platformFee(), 2500);
    }

    function testSetCustomPlatformFeeBasic() public
    {
        // act
        mFactory.setPlatformFeeForPair(address(mPair), 100);

        // assert
        assertEq(mPair.customPlatformFee(), 100);
        assertEq(mPair.platformFee(), 100);
    }

    function testSetCustomPlatformFeeOnThenOff() public
    {
        // arrange
        mFactory.setPlatformFeeForPair(address(mPair), 100);

        // act
        mFactory.setPlatformFeeForPair(address(mPair), 0);

        // assert
        assertEq(mPair.customPlatformFee(), 0);
        assertEq(mPair.platformFee(), 2500);
    }

    function testSetCustomPlatformFeeMoreThanMaxPlatformFee() public
    {
        // act & assert
        vm.expectRevert("UniswapV2: INVALID_PLATFORM_FEE");
        mFactory.setPlatformFeeForPair(address(mPair), 9000);
    }

    function testUpdateDefaultFees() public
    {
        // act
        mFactory.setDefaultSwapFee(200);
        mFactory.setDefaultPlatformFee(5000);

        mPair.updateSwapFee();
        mPair.updatePlatformFee();

        // assert
        assertEq(mPair.swapFee(), 200);
        assertEq(mPair.platformFee(), 5000);
    }
}
