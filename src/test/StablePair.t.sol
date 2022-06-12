pragma solidity ^0.8.0;

import "ds-test/test.sol";
import "forge-std/Vm.sol";

import "src/UniswapV2Factory.sol";
import "src/curve/stable/HybridPool.sol";
import "src/curve/constant-product/UniswapV2Pair.sol";
import "src/test/__fixtures/MintableERC20.sol";

contract StablePairTest is DSTest
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

    function createStablePair() private returns (address rPair)
    {
        rPair = mFactory.createPair(address(mTokenA), address(mTokenB), 1);
    }

    function createConstantProductPair() private returns (address rPair)
    {
        rPair = mFactory.createPair(address(mTokenA), address(mTokenB), 0);
    }

    function provideLiquidity(address aPairAddress) private
    {
        mTokenA.mint(aPairAddress, 100e18);
        mTokenB.mint(aPairAddress, 100e18);

        HybridPool(aPairAddress).mint(address(this));
    }

    function calculateConstantProductOutput(
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

    function testLiquidityProvision() public
    {
        // arrange
        address pairAddress = createStablePair();

        // act
        provideLiquidity(pairAddress);

        // assert
        (uint reserve0, uint reserve1) = HybridPool(pairAddress).getReserves();
        assertEq(reserve0, 100e18);
        assertEq(reserve1, 100e18);
        uint256 lpTokenBalance = HybridPool(pairAddress).balanceOf(address(this));
        assertEq(lpTokenBalance, 199999999999999999000);
    }

    function testSwapBasic() public
    {
        // arrange
        address pairAddress = createStablePair();
        provideLiquidity(pairAddress);
        uint256 swapAmount = 5e18;

        // act
        bytes memory getAmountOutArgs = abi.encode(address(mTokenA), swapAmount);
        uint256 expectedAmount = HybridPool(pairAddress).getAmountOut(getAmountOutArgs);

        mTokenA.mint(pairAddress, swapAmount);
        bytes memory swapArgs = abi.encode(address(mTokenA), address(this));
        HybridPool(pairAddress).swap(swapArgs);

        // assert
        assertEq(mTokenB.balanceOf(address(this)), expectedAmount);
    }

    function testStableVsConstantProduct() public
    {
        // arrange
        uint256 swapAmount = 5e18;

        address stable = createStablePair();
        provideLiquidity(stable);

        address constantProduct = createConstantProductPair();
        mTokenA.mint(constantProduct, 100e18);
        mTokenB.mint(constantProduct, 100e18);
        UniswapV2Pair(constantProduct).mint(address(this));
        uint256 expectedConstantProductOutput = calculateConstantProductOutput(100e18, 100e18, swapAmount, 30);

        // act
        mTokenA.mint(stable, swapAmount);
        bytes memory swapArgs = abi.encode(address(mTokenA), address(this));
        uint256 stableOutput = HybridPool(stable).swap(swapArgs);

        mTokenA.mint(constantProduct, swapAmount);
        UniswapV2Pair(constantProduct).swap(expectedConstantProductOutput, 0, address(this), "");
        uint256 constantProductOutput = mTokenB.balanceOf(address(this)) - stableOutput;

        // assert
        assertGt(stableOutput, constantProductOutput);
    }
}
