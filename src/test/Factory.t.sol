pragma solidity =0.8.13;

import "ds-test/test.sol";
import "forge-std/Vm.sol";

import "src/UniswapV2Factory.sol";
import "src/test/__fixtures/MintableERC20.sol";
import "src/UniswapV2Pair.sol";

contract FactoryTest is DSTest
{
	UniswapV2Factory private mFactory;
	address private mFeeToSetter = address(1);
	MintableERC20 private mTokenA = new MintableERC20("TokenA", "TA");
	MintableERC20 private mTokenB = new MintableERC20("TokenB", "TB");
	address private mSwapUser = address(2);

	function CalculateOutput(
        uint256 aReserveIn,
        uint256 aReserveOut,
        uint256 aTokenIn,
        uint256 aFee
    ) private pure returns (uint256 rExpectedOut)
    {
        // the following formula is taken from VexchangeV2Library, see:
        //
        // https://github.com/vexchange/vexchange-contracts/blob/183e8eef29dc9a28e0f84539bc2c66bb3f6103bf/
        // vexchange-v2-periphery/contracts/libraries/VexchangeV2Library.sol#L49
        uint256 lAmountInWithFee = aTokenIn * (10_000 - aFee);
        uint256 lNumerator = lAmountInWithFee * aReserveOut;
        uint256 lDenominator = aReserveIn * 10_000 + lAmountInWithFee;

        rExpectedOut = lNumerator / lDenominator;
    }

    function GetToken0Token1(address aTokenA, address aTokenB) private pure returns (address rToken0, address rToken1)
    {
    	(rToken0, rToken1) = aTokenA < aTokenB ? (aTokenA, aTokenB) : (aTokenB, aTokenA);
    }

	function setUp() public 
	{
		mFactory = new UniswapV2Factory(mFeeToSetter);
	}

	function testCreatePair() public returns (address rPairAddress)
	{
		// act
		rPairAddress = mFactory.createPair(address(mTokenA), address(mTokenB));
		
		// assert
		assertEq(mFactory.allPairs(0), rPairAddress); 
	}

	function testMinting() public returns (address rPairAddress)
	{
		// arrange
		rPairAddress = testCreatePair();

		mTokenA.mint(address(this), 100e18);
		mTokenB.mint(address(this), 100e18);

		// act 
		mTokenA.transfer(rPairAddress, 100e18);
		mTokenB.transfer(rPairAddress, 100e18);
		UniswapV2Pair(rPairAddress).mint(address(this));

		// assert
		uint256 lpTokenBalance = UniswapV2Pair(rPairAddress).balanceOf(address(this));
		assertEq(lpTokenBalance, 99999999999999999000);
		assertEq(mTokenA.balanceOf(address(this)), 0);
		assertEq(mTokenB.balanceOf(address(this)), 0);
	}

	function testSwap() public
	{
		// arrange
		address pairAddress = testMinting();
		uint256 reserve0;
		uint256 reserve1;
		(reserve0, reserve1, ) = UniswapV2Pair(pairAddress).getReserves();
		uint256 expectedOutput = CalculateOutput(reserve0, reserve1, 1e18, 30);

		// act
		address token0;
		address token1;
		(token0, token1) = GetToken0Token1(address(mTokenA), address(mTokenB));

		MintableERC20(token0).mint(address(this), 1e18);
		MintableERC20(token0).transfer(pairAddress, 1e18);
		UniswapV2Pair(pairAddress).swap(0, expectedOutput, address(this), "");

		// assert
		assertEq(MintableERC20(token1).balanceOf(address(this)), expectedOutput);
		assertEq(MintableERC20(token0).balanceOf(address(this)), 0);
	}

}