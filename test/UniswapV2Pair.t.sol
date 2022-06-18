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
        mPair = _createPair(mTokenA, mTokenB);
    }

    function _createPair(MintableERC20 aTokenA, MintableERC20 aTokenB) private returns (UniswapV2Pair rPair)
    {
        rPair = UniswapV2Pair(mFactory.createPair(address(aTokenA), address(aTokenB)));
    }

    function _provideLiquidity(address aPair) private
    {
        mTokenA.mint(address(this), 100e18);
        mTokenB.mint(address(this), 100e18);

        mTokenA.transfer(aPair, 100e18);
        mTokenB.transfer(aPair, 100e18);
        UniswapV2Pair(aPair).mint(address(this));
    }

    function _calculateOutput(
        uint256 aReserveIn,
        uint256 aReserveOut,
        uint256 aTokenIn,
        uint256 aFee
    ) private pure returns (uint256 rExpectedOut)
    {
        uint256 lAmountInWithFee = aTokenIn * (10_000 - aFee);
        uint256 lNumerator = lAmountInWithFee * aReserveOut;
        uint256 lDenominator = aReserveIn * 10_000 + lAmountInWithFee;

        rExpectedOut = lNumerator / lDenominator;
    }

    function _getToken0Token1(address aTokenA, address aTokenB) private pure returns (address rToken0, address rToken1)
    {
        (rToken0, rToken1) = aTokenA < aTokenB ? (aTokenA, aTokenB) : (aTokenB, aTokenA);
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

    function testMint() public
    {
        // act
        _provideLiquidity(address(mPair));

        // assert
        uint256 lpTokenBalance = mPair.balanceOf(address(this));
        assertEq(lpTokenBalance, 100e18 - mPair.MINIMUM_LIQUIDITY());
        assertEq(mTokenA.balanceOf(address(this)), 0);
        assertEq(mTokenB.balanceOf(address(this)), 0);
    }

    function testMint_UnderMinimumLiquidity() public
    {
        // arrange
        mTokenA.mint(address(mPair), 10);
        mTokenB.mint(address(mPair), 10);

        // act & assert
        vm.expectRevert(stdError.arithmeticError);
        mPair.mint(address(this));
    }

    function testMint_InitialMint() public
    {

    }

    function testSwap() public
    {
        // arrange
        _provideLiquidity(address(mPair));

        uint256 reserve0;
        uint256 reserve1;
        (reserve0, reserve1, ) = mPair.getReserves();
        uint256 expectedOutput = _calculateOutput(reserve0, reserve1, 1e18, 30);

        // act
        address token0;
        address token1;
        (token0, token1) = _getToken0Token1(address(mTokenA), address(mTokenB));

        MintableERC20(token0).mint(address(mPair), 1e18);
        mPair.swap(0, expectedOutput, address(this), "");

        // assert
        assertEq(MintableERC20(token1).balanceOf(address(this)), expectedOutput);
        assertEq(MintableERC20(token0).balanceOf(address(this)), 0);
    }

    function testBurn() public
    {
        // arrange
        _provideLiquidity(address(mPair));

        // act
        mPair.transfer(address(mPair), mPair.balanceOf(address(this)));
        mPair.burn(address(this));

        // assert
        assertEq(mPair.balanceOf(address(this)), 0);
        assertEq(mTokenA.balanceOf(address(this)), 100e18 - mPair.MINIMUM_LIQUIDITY());
        assertEq(mTokenB.balanceOf(address(this)), 100e18 - mPair.MINIMUM_LIQUIDITY());
    }
}
