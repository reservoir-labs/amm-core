pragma solidity =0.8.13;

import "forge-std/Test.sol";

import "test/__fixtures/MintableERC20.sol";

import "src/UniswapV2Factory.sol";
import "src/curve/constant-product/UniswapV2Pair.sol";

contract FactoryTest is Test
{
    address private mOwner = address(1);
    address private mSwapUser = address(2);
    address private mRecoverer = address(3);

    MintableERC20 private mTokenA = new MintableERC20("TokenA", "TA");
    MintableERC20 private mTokenB = new MintableERC20("TokenB", "TB");
    MintableERC20 private mTokenC = new MintableERC20("TokenC", "TC");

    UniswapV2Factory private mFactory;
    UniswapV2Pair private mPair;

    function setUp() public
    {
        mFactory = new UniswapV2Factory(30, 0, mOwner, mRecoverer);
        mPair = createPair(mTokenA, mTokenB);
    }

    function calculateOutput(
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

    function getToken0Token1(address aTokenA, address aTokenB) private pure returns (address rToken0, address rToken1)
    {
        (rToken0, rToken1) = aTokenA < aTokenB ? (aTokenA, aTokenB) : (aTokenB, aTokenA);
    }

    function createPair(MintableERC20 aTokenA, MintableERC20 aTokenB) private returns (UniswapV2Pair rPair)
    {
        rPair = UniswapV2Pair(mFactory.createPair(address(aTokenA), address(aTokenB)));
    }

    function provideLiquidity(address aPair) private
    {
        mTokenA.mint(address(this), 100e18);
        mTokenB.mint(address(this), 100e18);

        mTokenA.transfer(aPair, 100e18);
        mTokenB.transfer(aPair, 100e18);
        UniswapV2Pair(aPair).mint(address(this));
    }

    function testCreatePair() public
    {
        // act
        UniswapV2Pair pair = createPair(mTokenA, mTokenC);

        // assert
        assertEq(mFactory.allPairs(1), address(pair));
    }

    function testLiquidityProvision() public
    {
        // act
        provideLiquidity(address(mPair));

        // assert
        uint256 lpTokenBalance = mPair.balanceOf(address(this));
        assertEq(lpTokenBalance, 99999999999999999000);
        assertEq(mTokenA.balanceOf(address(this)), 0);
        assertEq(mTokenB.balanceOf(address(this)), 0);
    }

    function testSwap() public
    {
        // arrange
        provideLiquidity(address(mPair));

        uint256 reserve0;
        uint256 reserve1;
        (reserve0, reserve1, ) = mPair.getReserves();
        uint256 expectedOutput = calculateOutput(reserve0, reserve1, 1e18, 30);

        // act
        address token0;
        address token1;
        (token0, token1) = getToken0Token1(address(mTokenA), address(mTokenB));

        MintableERC20(token0).mint(address(mPair), 1e18);
        mPair.swap(0, expectedOutput, address(this), "");

        // assert
        assertEq(MintableERC20(token1).balanceOf(address(this)), expectedOutput);
        assertEq(MintableERC20(token0).balanceOf(address(this)), 0);
    }
}
