pragma solidity =0.8.13;

import "ds-test/test.sol";
import "forge-std/Vm.sol";

import "src/UniswapV2Factory.sol";
import "src/test/__fixtures/MintableERC20.sol";
import "src/UniswapV2Pair.sol";

contract FactoryTest is DSTest
{
    address private mOwner = address(1);
    address private mSwapUser = address(2);
    address private mRecoverer = address(3);

    MintableERC20 private mTokenA = new MintableERC20("TokenA", "TA", 18);
    MintableERC20 private mTokenB = new MintableERC20("TokenB", "TB", 18);

    UniswapV2Factory private mFactory;

    function setUp() public
    {
        mFactory = new UniswapV2Factory(30, 0, mOwner, mRecoverer);
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

    function createPair() private returns (address rPairAddress)
    {
        rPairAddress = mFactory.createPair(address(mTokenA), address(mTokenB), 0);
    }

    function provideLiquidity(address aPairAddress) private
    {
        mTokenA.mint(address(this), 100e18);
        mTokenB.mint(address(this), 100e18);

        mTokenA.transfer(aPairAddress, 100e18);
        mTokenB.transfer(aPairAddress, 100e18);
        UniswapV2Pair(aPairAddress).mint(address(this));
    }

    function testCreatePair() public
    {
        // act
        address pairAddress = createPair();

        // assert
        assertEq(mFactory.allPairs(0), pairAddress);
    }

    function testLiquidityProvision() public
    {
        // arrange
        address pairAddress = createPair();

        // act
        provideLiquidity(pairAddress);

        // assert
        uint256 lpTokenBalance = UniswapV2Pair(pairAddress).balanceOf(address(this));
        assertEq(lpTokenBalance, 99999999999999999000);
        assertEq(mTokenA.balanceOf(address(this)), 0);
        assertEq(mTokenB.balanceOf(address(this)), 0);
    }

    function testSwap() public
    {
        // arrange
        address pairAddress = createPair();
        provideLiquidity(pairAddress);

        uint256 reserve0;
        uint256 reserve1;
        (reserve0, reserve1, ) = UniswapV2Pair(pairAddress).getReserves();
        uint256 expectedOutput = calculateOutput(reserve0, reserve1, 1e18, 30);

        // act
        address token0;
        address token1;
        (token0, token1) = getToken0Token1(address(mTokenA), address(mTokenB));

        MintableERC20(token0).mint(pairAddress, 1e18);
        UniswapV2Pair(pairAddress).swap(0, expectedOutput, address(this), "");

        // assert
        assertEq(MintableERC20(token1).balanceOf(address(this)), expectedOutput);
        assertEq(MintableERC20(token0).balanceOf(address(this)), 0);
    }
}
