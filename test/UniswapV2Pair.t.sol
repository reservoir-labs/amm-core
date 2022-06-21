pragma solidity =0.8.13;

import "forge-std/Test.sol";

import "test/__fixtures/MintableERC20.sol";
import "src/libraries/Math.sol";
import "src/UniswapV2Factory.sol";
import "src/curve/constant-product/UniswapV2Pair.sol";

contract UniswapV2PairTest is Test
{
    uint256 public constant INITIAL_MINT_AMOUNT = 100e18;

    address private _owner = address(1);
    address private _recoverer = address(2);
    address private _alice = address(3);

    MintableERC20 private _tokenA = new MintableERC20("TokenA", "TA");
    MintableERC20 private _tokenB = new MintableERC20("TokenB", "TB");
    MintableERC20 private _tokenC = new MintableERC20("TokenC", "TC");

    UniswapV2Factory private _factory = new UniswapV2Factory(30, 2500, _owner, _recoverer);
    UniswapV2Pair private _pair = _createPair(_tokenA, _tokenB);

    function setUp() public
    {
        _tokenA.mint(address(_pair), INITIAL_MINT_AMOUNT);
        _tokenB.mint(address(_pair), INITIAL_MINT_AMOUNT);
        UniswapV2Pair(_pair).mint(_alice);
    }

    function _createPair(MintableERC20 aTokenA, MintableERC20 aTokenB) private returns (UniswapV2Pair rPair)
    {
        rPair = UniswapV2Pair(_factory.createPair(address(aTokenA), address(aTokenB)));
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

    function testCustomSwapFee_OffByDefault() public
    {
        // assert
        assertEq(_pair.customSwapFee(), 0);
        assertEq(_pair.swapFee(), 30);
    }

    function testSetSwapFeeForPair() public
    {
        // act
        _factory.setSwapFeeForPair(address(_pair), 100);

        // assert
        assertEq(_pair.customSwapFee(), 100);
        assertEq(_pair.swapFee(), 100);
    }

    function testSetSwapFeeForPair_Reset() public
    {
        // arrange
        _factory.setSwapFeeForPair(address(_pair), 100);

        // act
        _factory.setSwapFeeForPair(address(_pair), 0);

        // assert
        assertEq(_pair.customSwapFee(), 0);
        assertEq(_pair.swapFee(), 30);
    }

    function testSetSwapFeeForPair_BreachMaximum() public
    {
        // act & assert
        vm.expectRevert("UniswapV2: INVALID_SWAP_FEE");
        _factory.setSwapFeeForPair(address(_pair), 4000);
    }

    function testCustomPlatformFee_OffByDefault() public
    {
        // assert
        assertEq(_pair.customPlatformFee(), 0);
        assertEq(_pair.platformFee(), 2500);
    }

    function testSetPlatformFeeForPair() public
    {
        // act
        _factory.setPlatformFeeForPair(address(_pair), 100);

        // assert
        assertEq(_pair.customPlatformFee(), 100);
        assertEq(_pair.platformFee(), 100);
    }

    function testSetPlatformFeeForPair_Reset() public
    {
        // arrange
        _factory.setPlatformFeeForPair(address(_pair), 100);

        // act
        _factory.setPlatformFeeForPair(address(_pair), 0);

        // assert
        assertEq(_pair.customPlatformFee(), 0);
        assertEq(_pair.platformFee(), 2500);
    }

    function testSetPlatformFeeForPair_BreachMaximum() public
    {
        // act & assert
        vm.expectRevert("UniswapV2: INVALID_PLATFORM_FEE");
        _factory.setPlatformFeeForPair(address(_pair), 9000);
    }

    function testUpdateDefaultFees() public
    {
        // arrange
        _factory.setDefaultSwapFee(200);
        _factory.setDefaultPlatformFee(5000);

        // act
        _pair.updateSwapFee();
        _pair.updatePlatformFee();

        // assert
        assertEq(_pair.swapFee(), 200);
        assertEq(_pair.platformFee(), 5000);
    }

    function testMint() public
    {
        // arrange
        uint256 lLpTokenBalanceBefore = _pair.balanceOf(address(this));
        uint256 lTotalSupplyLpToken = _pair.totalSupply();
        uint256 lLiquidityToAdd = 5e18;
        (uint256 reserve0, , ) = _pair.getReserves();

        // act
        _tokenA.mint(address(_pair), lLiquidityToAdd);
        _tokenB.mint(address(_pair), lLiquidityToAdd);
        _pair.mint(address(this));

        // assert
        uint256 lAdditionalLpTokens = lLiquidityToAdd * lTotalSupplyLpToken / reserve0;
        assertEq(_pair.balanceOf(address(this)), lLpTokenBalanceBefore + lAdditionalLpTokens);
    }

    function testMint_InitialMint() public
    {
        // assert
        uint256 lpTokenBalance = _pair.balanceOf(_alice);
        uint256 lExpectedLpTokenBalance = Math.sqrt(INITIAL_MINT_AMOUNT ** 2) - _pair.MINIMUM_LIQUIDITY();
        assertEq(lpTokenBalance, lExpectedLpTokenBalance);
    }

    function testMint_MinimumLiquidity() public
    {
        // arrange
        UniswapV2Pair lPair = _createPair(_tokenA, _tokenC);
        _tokenA.mint(address(lPair), 1000);
        _tokenC.mint(address(lPair), 1000);

        // act & assert
        vm.expectRevert("UniswapV2: INSUFFICIENT_LIQUIDITY_MINTED");
        lPair.mint(address(this));
    }

    function testMint_UnderMinimumLiquidity() public
    {
        // arrange
        UniswapV2Pair lPair = _createPair(_tokenA, _tokenC);
        _tokenA.mint(address(lPair), 10);
        _tokenB.mint(address(lPair), 10);

        // act & assert
        vm.expectRevert(stdError.arithmeticError);
        lPair.mint(address(this));
    }

    function testSwap() public
    {
        // arrange
        (uint256 reserve0, uint256 reserve1, ) = _pair.getReserves();
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
        vm.startPrank(_alice);
        uint256 lLpTokenBalance = _pair.balanceOf(_alice);
        uint256 lLpTokenTotalSupply = _pair.totalSupply();
        (uint256 lReserve0, uint256 lReserve1, ) = _pair.getReserves();

        // act
        _pair.transfer(address(_pair), _pair.balanceOf(_alice));
        _pair.burn(_alice);

        // assert
        assertEq(_pair.balanceOf(_alice), 0);
        (address lToken0, address lToken1) = _getToken0Token1(address(_tokenA), address(_tokenB));
        assertEq(UniswapV2Pair(lToken0).balanceOf(_alice), lLpTokenBalance * lReserve0 / lLpTokenTotalSupply);
        assertEq(UniswapV2Pair(lToken1).balanceOf(_alice), lLpTokenBalance * lReserve1 / lLpTokenTotalSupply);
    }
}
