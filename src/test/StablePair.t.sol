pragma solidity ^0.8.0;

import "ds-test/test.sol";
import "forge-std/Vm.sol";

import "@openzeppelin/token/ERC20/IERC20.sol";
import "src/UniswapV2Factory.sol";
import "src/curve/stable/UniswapV2StablePair.sol";
import "src/curve/stable/StableMath.sol";
import "src/test/__fixtures/MintableERC20.sol";

contract StablePairTest is DSTest {
    Vm private vm = Vm(HEVM_ADDRESS);

    address private mOwner = address(1);
    address private mRecoverer = address(3);

    MintableERC20 private mTokenA = new MintableERC20("StableA", "TA", 18);
    MintableERC20 private mTokenB = new MintableERC20("StableB", "TB", 6);
    MintableERC20 private mTokenC = new MintableERC20("ManyDecimals", "MD", 21);

    UniswapV2Factory private mFactory;

    function setUp() public
    {
        mFactory = new UniswapV2Factory(30, 2500, mOwner, mRecoverer);
    }

    function createStablePair() private returns (address rPairAddress)
    {
        rPairAddress = mFactory.createPair(address(mTokenA), address(mTokenB), 1);
    }

    function provideLiquidity(address aPairAddress) private returns (uint lpTokenAmount)
    {
        // arrange
        mTokenA.mint(aPairAddress, 100e18);
        mTokenB.mint(aPairAddress, 100e6);

        // act
        lpTokenAmount = UniswapV2StablePair(aPairAddress).mint(address(this));
    }

    function testCreatePair() public
    {
        // arrange
        address pairAddress = createStablePair();
        (uint currentAmp, ,) = UniswapV2StablePair(pairAddress).getAmplificationParameter();

        // assert
        assertEq(currentAmp, mFactory.defaultAmplificationCoefficient() * StableMath._AMP_PRECISION);
        assertEq(UniswapV2StablePair(pairAddress)._getScalingFactor0(), 1e30);
        assertEq(UniswapV2StablePair(pairAddress)._getScalingFactor1(), 1e18);
    }

    function testCreatePairMoreThan18Decimals() public
    {
        // act & assert
        vm.expectRevert("BAL#001");
        mFactory.createPair(address(mTokenA), address(mTokenC), 1);
    }

    function testAddLiquidityBasic() public
    {
        // arrange
        address pairAddress = createStablePair();

        // act
        uint lpTokenAmount = provideLiquidity(pairAddress);

        // assert
        assertEq(IERC20(pairAddress).balanceOf(address(this)), lpTokenAmount);
        assertEq(IERC20(pairAddress).balanceOf(address(0)), UniswapV2StablePair(pairAddress).MINIMUM_LIQUIDITY());

        (uint lastInvariant, ) = UniswapV2StablePair(pairAddress).getLastInvariant();
        assertEq(lpTokenAmount, lastInvariant);
    }

    function testAddLiquidityWrongAmount() public
    {
        // arrange
        address pairAddress = createStablePair();

        // act
        mTokenA.mint(pairAddress, 100e18);
        mTokenB.mint(pairAddress, 5e6);
        uint lpTokenAmount = UniswapV2StablePair(pairAddress).mint(address(this));

        // assert
        assertEq(IERC20(pairAddress).balanceOf(address(this)), 100e18);
        emit log_uint(lpTokenAmount);
    }

    function testSwapBasic() public
    {

    }

    function testRemoveLiquidityBasic() public
    {

    }
}
