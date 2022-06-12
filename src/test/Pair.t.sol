pragma solidity =0.8.13;

import "ds-test/test.sol";
import "forge-std/Vm.sol";

import "src/UniswapV2Factory.sol";
import "src/curve/constant-product/UniswapV2Pair.sol";
import "src/test/__fixtures/MintableERC20.sol";

contract PairTest is DSTest
{
    Vm private vm = Vm(HEVM_ADDRESS);

    address private mOwner = address(1);
    address private mRecoverer = address(3);

    MintableERC20 private mTokenA = new MintableERC20("TokenA", "TA");
    MintableERC20 private mTokenB = new MintableERC20("TokenB", "TB");

    UniswapV2Factory private mFactory;

    function setUp() public
    {
        mFactory = new UniswapV2Factory(30, 2500, mOwner, mRecoverer);
    }

    function createPair() private returns (address rPair)
    {
        rPair = mFactory.createPair(address(mTokenA), address(mTokenB), 0);
    }

    function testCustomSwapFeeOffByDefault() public
    {
        // arrange
        address pair = createPair();

        // assert
        assertEq(UniswapV2Pair(pair).customSwapFee(), 0);
        assertEq(UniswapV2Pair(pair).swapFee(), 30);
    }

    function testSetCustomSwapFeeBasic() public
    {
        // arrange
        address pair = createPair();

        // act
        mFactory.setSwapFeeForPair(pair, 100);

        // assert
        assertEq(UniswapV2Pair(pair).customSwapFee(), 100);
        assertEq(UniswapV2Pair(pair).swapFee(), 100);
    }

    function testSetCustomSwapFeeOnThenOff() public
    {
        // arrange
        address pair = createPair();
        mFactory.setSwapFeeForPair(pair, 100);

        // act
        mFactory.setSwapFeeForPair(pair, 0);

        // assert
        assertEq(UniswapV2Pair(pair).customSwapFee(), 0);
        assertEq(UniswapV2Pair(pair).swapFee(), 30);
    }

    function testSetCustomSwapFeeMoreThanMaxSwapFee() public
    {
        // arrange
        address pair = createPair();

        // act & assert
        vm.expectRevert("UniswapV2: INVALID_SWAP_FEE");
        mFactory.setSwapFeeForPair(pair, 4000);
    }

    function testCustomPlatformFeeOffByDefault() public
    {
        // arrange
        address pair = createPair();

        // assert
        assertEq(UniswapV2Pair(pair).customPlatformFee(), 0);
        assertEq(UniswapV2Pair(pair).platformFee(), 2500);
    }

    function testSetCustomPlatformFeeBasic() public
    {
        // arrange
        address pair = createPair();

        // act
        mFactory.setPlatformFeeForPair(pair, 100);

        // assert
        assertEq(UniswapV2Pair(pair).customPlatformFee(), 100);
        assertEq(UniswapV2Pair(pair).platformFee(), 100);
    }

    function testSetCustomPlatformFeeOnThenOff() public
    {
        // arrange
        address pair = createPair();
        mFactory.setPlatformFeeForPair(pair, 100);

        // act
        mFactory.setPlatformFeeForPair(pair, 0);

        // assert
        assertEq(UniswapV2Pair(pair).customPlatformFee(), 0);
        assertEq(UniswapV2Pair(pair).platformFee(), 2500);
    }

    function testSetCustomPlatformFeeMoreThanMaxPlatformFee() public
    {
        // arrange
        address pair = createPair();

        // act & assert
        vm.expectRevert("UniswapV2: INVALID_PLATFORM_FEE");
        mFactory.setPlatformFeeForPair(pair, 9000);
    }

    function testUpdateDefaultFees() public
    {
        // arrange
        address pair = createPair();

        // act
        mFactory.setDefaultSwapFee(200);
        mFactory.setDefaultPlatformFee(5000);

        UniswapV2Pair(pair).updateSwapFee();
        UniswapV2Pair(pair).updatePlatformFee();

        // assert
        assertEq(UniswapV2Pair(pair).swapFee(), 200);
        assertEq(UniswapV2Pair(pair).platformFee(), 5000);
    }
}
