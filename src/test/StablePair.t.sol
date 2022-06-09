pragma solidity ^0.8.0;

import "ds-test/test.sol";
import "forge-std/Vm.sol";

import "src/UniswapV2Factory.sol";
import "src/curve/stable/HybridPool.sol";
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

    function createStablePair() private returns (address rPairAddress)
    {
        rPairAddress = mFactory.createPair(address(mTokenA), address(mTokenB), 1);
    }

    function createConstantProductPair() private returns (address rPairAddress)
    {
        rPairAddress = mFactory.createPair(address(mTokenA), address(mTokenB), 0);
    }
    function provideLiquidity(address aPairAddress) private
    {
        mTokenA.mint(aPairAddress, 100e18);
        mTokenB.mint(aPairAddress, 100e18);

        HybridPool(aPairAddress).mint(address(this));
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

    function testSwap() public
    {
        // arrange
        address pairAddress = createStablePair();
        provideLiquidity(pairAddress);
        uint256 swapAmount = 5e8;

        // act
        mTokenA.mint(pairAddress, swapAmount);
        bytes memory swapArgs = abi.encode(address(mTokenA), address(this));
        HybridPool(pairAddress).swap(swapArgs);

        // assert
        bytes memory getAmountOutArgs = abi.encode(address(mTokenA), swapAmount);
        uint256 expectedAmount = HybridPool(pairAddress).getAmountOut(getAmountOutArgs);
        assertEq(mTokenB.balanceOf(address(this)), expectedAmount);
    }
}
