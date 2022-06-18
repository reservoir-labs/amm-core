pragma solidity =0.8.13;

import "forge-std/Test.sol";

import "test/__fixtures/MintableERC20.sol";

import "src/UniswapV2Factory.sol";
import "src/curve/constant-product/UniswapV2Pair.sol";

contract PairTest is Test
{
    address private _owner = address(1);
    address private _recoverer = address(3);

    MintableERC20 private _tokenA = new MintableERC20("TokenA", "TA");
    MintableERC20 private _tokenB = new MintableERC20("TokenB", "TB");

    UniswapV2Factory private _factory;
    UniswapV2Pair private _pair;

    function setUp() public
    {
        _factory = new UniswapV2Factory(30, 2500, _owner, _recoverer);
        _pair = _createPair(_tokenA, _tokenB);
    }

    function _createPair(MintableERC20 aTokenA, MintableERC20 aTokenB) private returns (UniswapV2Pair rPair)
    {
        rPair = UniswapV2Pair(_factory.createPair(address(aTokenA), address(aTokenB)));
    }

    function _provideLiquidity(address aPair) private
    {
        _tokenA.mint(address(this), 100e18);
        _tokenB.mint(address(this), 100e18);

        _tokenA.transfer(aPair, 100e18);
        _tokenB.transfer(aPair, 100e18);
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
        assertEq(_pair.customSwapFee(), 0);
        assertEq(_pair.swapFee(), 30);
    }

    function testSetCustomSwapFeeBasic() public
    {
        // act
        _factory.setSwapFeeForPair(address(_pair), 100);

        // assert
        assertEq(_pair.customSwapFee(), 100);
        assertEq(_pair.swapFee(), 100);
    }

    function testSetCustomSwapFeeOnThenOff() public
    {
        // arrange
        _factory.setSwapFeeForPair(address(_pair), 100);

        // act
        _factory.setSwapFeeForPair(address(_pair), 0);

        // assert
        assertEq(_pair.customSwapFee(), 0);
        assertEq(_pair.swapFee(), 30);
    }

    function testSetCustomSwapFeeMoreThanMaxSwapFee() public
    {
        // act & assert
        vm.expectRevert("UniswapV2: INVALID_SWAP_FEE");
        _factory.setSwapFeeForPair(address(_pair), 4000);
    }

    function testCustomPlatformFeeOffByDefault() public
    {
        // assert
        assertEq(_pair.customPlatformFee(), 0);
        assertEq(_pair.platformFee(), 2500);
    }

    function testSetCustomPlatformFeeBasic() public
    {
        // act
        _factory.setPlatformFeeForPair(address(_pair), 100);

        // assert
        assertEq(_pair.customPlatformFee(), 100);
        assertEq(_pair.platformFee(), 100);
    }

    function testSetCustomPlatformFeeOnThenOff() public
    {
        // arrange
        _factory.setPlatformFeeForPair(address(_pair), 100);

        // act
        _factory.setPlatformFeeForPair(address(_pair), 0);

        // assert
        assertEq(_pair.customPlatformFee(), 0);
        assertEq(_pair.platformFee(), 2500);
    }

    function testSetCustomPlatformFeeMoreThanMaxPlatformFee() public
    {
        // act & assert
        vm.expectRevert("UniswapV2: INVALID_PLATFORM_FEE");
        _factory.setPlatformFeeForPair(address(_pair), 9000);
    }

    function testUpdateDefaultFees() public
    {
        // act
        _factory.setDefaultSwapFee(200);
        _factory.setDefaultPlatformFee(5000);

        _pair.updateSwapFee();
        _pair.updatePlatformFee();

        // assert
        assertEq(_pair.swapFee(), 200);
        assertEq(_pair.platformFee(), 5000);
    }

    function testMint() public
    {
        // act
        _provideLiquidity(address(_pair));

        // assert
        uint256 lpTokenBalance = _pair.balanceOf(address(this));
        assertEq(lpTokenBalance, 100e18 - _pair.MINIMUM_LIQUIDITY());
        assertEq(_tokenA.balanceOf(address(this)), 0);
        assertEq(_tokenB.balanceOf(address(this)), 0);
    }

    function testMint_UnderMinimumLiquidity() public
    {
        // arrange
        _tokenA.mint(address(_pair), 10);
        _tokenB.mint(address(_pair), 10);

        // act & assert
        vm.expectRevert(stdError.arithmeticError);
        _pair.mint(address(this));
    }

    function testMint_InitialMint() public
    {

    }

    function testSwap() public
    {
        // arrange
        _provideLiquidity(address(_pair));

        uint256 reserve0;
        uint256 reserve1;
        (reserve0, reserve1, ) = _pair.getReserves();
        uint256 expectedOutput = _calculateOutput(reserve0, reserve1, 1e18, 30);

        // act
        address token0;
        address token1;
        (token0, token1) = _getToken0Token1(address(_tokenA), address(_tokenB));

        MintableERC20(token0).mint(address(_pair), 1e18);
        _pair.swap(0, expectedOutput, address(this), "");

        // assert
        assertEq(MintableERC20(token1).balanceOf(address(this)), expectedOutput);
        assertEq(MintableERC20(token0).balanceOf(address(this)), 0);
    }

    function testBurn() public
    {
        // arrange
        _provideLiquidity(address(_pair));

        // act
        _pair.transfer(address(_pair), _pair.balanceOf(address(this)));
        _pair.burn(address(this));

        // assert
        assertEq(_pair.balanceOf(address(this)), 0);
        assertEq(_tokenA.balanceOf(address(this)), 100e18 - _pair.MINIMUM_LIQUIDITY());
        assertEq(_tokenB.balanceOf(address(this)), 100e18 - _pair.MINIMUM_LIQUIDITY());
    }
}
