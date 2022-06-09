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
        mFactory.setSwapFeeForPair(pairAddress, 100);

        // assert
        assertEq(UniswapV2Pair(pairAddress).customSwapFee(), 100);
        assertEq(UniswapV2Pair(pairAddress).swapFee(), 100);
    }

    function testSetCustomSwapFeeOnThenOff() public
    {
        // arrange
        address pairAddress = createPair();
        mFactory.setSwapFeeForPair(pairAddress, 100);

        // act
        mFactory.setSwapFeeForPair(pairAddress, 0);

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
        mFactory.setSwapFeeForPair(pairAddress, 4000);
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
        mFactory.setPlatformFeeForPair(pairAddress, 100);

        // assert
        assertEq(UniswapV2Pair(pairAddress).customPlatformFee(), 100);
        assertEq(UniswapV2Pair(pairAddress).platformFee(), 100);
    }

    function testSetCustomPlatformFeeOnThenOff() public
    {
        // arrange
        address pairAddress = createPair();
        mFactory.setPlatformFeeForPair(pairAddress, 100);

        // act
        mFactory.setPlatformFeeForPair(pairAddress, 0);

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
        mFactory.setPlatformFeeForPair(pairAddress, 9000);
    }

    function testUpdateDefaultFees() public
    {
        // arrange
        address pairAddress = createPair();

        // act
        mFactory.setDefaultSwapFee(200);
        mFactory.setDefaultPlatformFee(5000);

        UniswapV2Pair(pairAddress).updateSwapFee();
        UniswapV2Pair(pairAddress).updatePlatformFee();

        // assert
        assertEq(UniswapV2Pair(pairAddress).swapFee(), 200);
        assertEq(UniswapV2Pair(pairAddress).platformFee(), 5000);
    }
}
