pragma solidity =0.8.13;

import "forge-std/Test.sol";

import { IERC20 } from "@openzeppelin/token/ERC20/IERC20.sol";

import { MintableERC20 } from "test/__fixtures/MintableERC20.sol";
import { AssetManager } from "test/__mocks/AssetManager.sol";

import { Math } from "src/libraries/Math.sol";
import { IAssetManager } from "src/interfaces/IAssetManager.sol";
import { GenericFactory } from "src/GenericFactory.sol";
import { UniswapV2Pair } from "src/curve/constant-product/UniswapV2Pair.sol";

contract UniswapV2PairTest is Test
{
    uint256 public constant INITIAL_MINT_AMOUNT = 100e18;

    address private _owner = address(1);
    address private _recoverer = address(2);
    address private _alice = address(3);

    MintableERC20 private _tokenA = new MintableERC20("TokenA", "TA");
    MintableERC20 private _tokenB = new MintableERC20("TokenB", "TB");
    MintableERC20 private _tokenC = new MintableERC20("TokenC", "TC");

    AssetManager private _manager = new AssetManager();
    GenericFactory private _factory = new GenericFactory();
    UniswapV2Pair private _pair;

    function setUp() public
    {
        // add constant product curve
        _factory.addCurve(type(UniswapV2Pair).creationCode);
        _factory.set(keccak256("UniswapV2Pair::swapFee"), bytes32(uint256(30)));
        _factory.set(keccak256("UniswapV2Pair::platformFee"), bytes32(uint256(2500)));

        // initial mint
        _pair = _createPair(_tokenA, _tokenB);
        _tokenA.mint(address(_pair), INITIAL_MINT_AMOUNT);
        _tokenB.mint(address(_pair), INITIAL_MINT_AMOUNT);
        _pair.mint(_alice);
    }

    function _createPair(MintableERC20 aTokenA, MintableERC20 aTokenB) private returns (UniswapV2Pair rPair)
    {
        rPair = UniswapV2Pair(_factory.createPair(address(aTokenA), address(aTokenB), 0));
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
        assertEq(_pair.customSwapFee(), type(uint).max);
        assertEq(_pair.swapFee(), 30);
    }

    function testSetSwapFeeForPair() public
    {
        // act
        _factory.rawCall(
            address(_pair),
            abi.encodeWithSignature("setCustomSwapFee(uint256)", 100),
            0
        );

        // assert
        assertEq(_pair.customSwapFee(), 100);
        assertEq(_pair.swapFee(), 100);
    }

    function testSetSwapFeeForPair_Reset() public
    {
        // arrange
        _factory.rawCall(
            address(_pair),
            abi.encodeWithSignature("setCustomSwapFee(uint256)", 100),
            0
        );

        // act
        _factory.rawCall(
            address(_pair),
            abi.encodeWithSignature("setCustomSwapFee(uint256)", type(uint).max),
            0
        );

        // assert
        assertEq(_pair.customSwapFee(), type(uint).max);
        assertEq(_pair.swapFee(), 30);
    }

    function testSetSwapFeeForPair_BreachMaximum() public
    {
        // act & assert
        vm.expectRevert("UniswapV2: INVALID_SWAP_FEE");
        _factory.rawCall(
            address(_pair),
            abi.encodeWithSignature("setCustomSwapFee(uint256)", 4000),
            0
        );
    }

    function testCustomPlatformFee_OffByDefault() public
    {
        // assert
        assertEq(_pair.customPlatformFee(), type(uint).max);
        assertEq(_pair.platformFee(), 2500);
    }

    function testSetPlatformFeeForPair() public
    {
        // act
        _factory.rawCall(
            address(_pair),
            abi.encodeWithSignature("setCustomPlatformFee(uint256)", 100),
            0
        );

        // assert
        assertEq(_pair.customPlatformFee(), 100);
        assertEq(_pair.platformFee(), 100);
    }

    function testSetPlatformFeeForPair_Reset() public
    {
        // arrange
        _factory.rawCall(
            address(_pair),
            abi.encodeWithSignature("setCustomPlatformFee(uint256)", 100),
            0
        );

        // act
        _factory.rawCall(
            address(_pair),
            abi.encodeWithSignature("setCustomPlatformFee(uint256)", type(uint).max),
            0
        );

        // assert
        assertEq(_pair.customPlatformFee(), type(uint).max);
        assertEq(_pair.platformFee(), 2500);
    }

    function testSetPlatformFeeForPair_BreachMaximum() public
    {
        // act & assert
        vm.expectRevert("UniswapV2: INVALID_PLATFORM_FEE");
        _factory.rawCall(
            address(_pair),
            abi.encodeWithSignature("setCustomPlatformFee(uint256)", 9000),
            0
        );
    }

    function testUpdateDefaultFees() public
    {
        // arrange
        _factory.set(keccak256("UniswapV2Pair::swapFee"), bytes32(uint256(200)));
        _factory.set(keccak256("UniswapV2Pair::platformFee"), bytes32(uint256(5000)));

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
        uint256 lTotalSupplyLpToken = _pair.totalSupply();
        uint256 lLiquidityToAdd = 5e18;
        (uint256 reserve0, , ) = _pair.getReserves();

        // act
        _tokenA.mint(address(_pair), lLiquidityToAdd);
        _tokenB.mint(address(_pair), lLiquidityToAdd);
        _pair.mint(address(this));

        // assert
        uint256 lAdditionalLpTokens = lLiquidityToAdd * lTotalSupplyLpToken / reserve0;
        assertEq(_pair.balanceOf(address(this)), lAdditionalLpTokens);
    }

    function testMint_InitialMint() public
    {
        // assert
        uint256 lpTokenBalance = _pair.balanceOf(_alice);
        uint256 lExpectedLpTokenBalance = Math.sqrt(INITIAL_MINT_AMOUNT ** 2) - _pair.MINIMUM_LIQUIDITY();
        assertEq(lpTokenBalance, lExpectedLpTokenBalance);
    }

    function testMint_JustAboveMinimumLiquidity() public
    {
        // arrange
        UniswapV2Pair lPair = _createPair(_tokenA, _tokenC);

        // act
        _tokenA.mint(address(lPair), 1001);
        _tokenC.mint(address(lPair), 1001);
        lPair.mint(address(this));

        // assert
        assertEq(lPair.balanceOf(address(this)), 1);
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

    /*//////////////////////////////////////////////////////////////////////////
                                    ASSET MANAGEMENT
    //////////////////////////////////////////////////////////////////////////*/

    function testManageReserves() external
    {
        // arrange
        _tokenA.mint(address(_pair), 50e18);
        _tokenB.mint(address(_pair), 50e18);
        _pair.mint(address(this));

        vm.prank(address(_factory));
        _pair.setManager(IAssetManager(address(this)));

        // act
        _pair.adjustInvestment(20e18, 20e18);

        // assert
        assertEq(_tokenA.balanceOf(address(this)), 20e18);
        assertEq(_tokenB.balanceOf(address(this)), 20e18);
    }

    function testManageReserves_KStillHolds() external
    {
        // arrange
        vm.prank(address(_factory));
        _pair.setManager(_manager);

        // liquidity prior to adjustInvestment
        _tokenA.mint(address(_pair), 50e18);
        _tokenB.mint(address(_pair), 50e18);
        uint256 lLiq1 = _pair.mint(address(this));

        _manager.adjustInvestment(_pair, 50e18, 50e18);

        // act
        _tokenA.mint(address(_pair), 50e18);
        _tokenB.mint(address(_pair), 50e18);
        uint256 lLiq2 = _pair.mint(address(this));

        // assert
        assertEq(lLiq1, lLiq2);
    }

    function testManageReserves_DecreaseInvestment() external
    {
        // arrange
        vm.prank(address(_factory));
        _pair.setManager(_manager);

        address lToken0 = _pair.token0();
        address lToken1 = _pair.token1();

        // sanity
        (uint112 lReserve0, uint112 lReserve1, ) = _pair.getReserves();
        uint256 lBal0Before = IERC20(lToken0).balanceOf(address(_pair));
        uint256 lBal1Before = IERC20(lToken1).balanceOf(address(_pair));

        _manager.adjustInvestment(_pair, 20e18, 20e18);

        (uint112 lReserve0_1, uint112 lReserve1_1, ) = _pair.getReserves();
        uint256 lBal0After = IERC20(lToken0).balanceOf(address(_pair));
        uint256 lBal1After = IERC20(lToken1).balanceOf(address(_pair));

        assertEq(uint256(lReserve0_1), lReserve0);
        assertEq(uint256(lReserve1_1), lReserve1);
        assertEq(lBal0Before - lBal0After, 20e18);
        assertEq(lBal1Before - lBal1After, 20e18);

        assertEq(IERC20(lToken0).balanceOf(address(_manager)), 20e18);
        assertEq(IERC20(lToken1).balanceOf(address(_manager)), 20e18);
        assertEq(_manager.getBalance(address(_pair), address(lToken0)), 20e18);
        assertEq(_manager.getBalance(address(_pair), address(lToken1)), 20e18);

        // act
        _manager.adjustInvestment(_pair, -10e18, -10e18);

        (uint112 lReserve0_2, uint112 lReserve1_2, ) = _pair.getReserves();

        // assert
        assertEq(uint256(lReserve0_2), lReserve0);
        assertEq(uint256(lReserve1_2), lReserve1);
        assertEq(IERC20(lToken0).balanceOf(address(_manager)), 10e18);
        assertEq(IERC20(lToken1).balanceOf(address(_manager)), 10e18);
        assertEq(_manager.getBalance(address(_pair), address(lToken0)), 10e18);
        assertEq(_manager.getBalance(address(_pair), address(lToken1)), 10e18);
    }

    function testSyncInvested() external
    {
        // arrange
        vm.prank(address(_factory));
        _pair.setManager(_manager);

        address lToken0 = _pair.token0();
        address lToken1 = _pair.token1();

        _manager.adjustInvestment(_pair, 20e18, 20e18);
        _tokenA.mint(address(_pair), 10e18);
        _tokenB.mint(address(_pair), 10e18);
        uint256 lLiq = _pair.mint(address(this));

        // sanity
        assertEq(lLiq, 10e18); // sqrt(10e18, 10e18)
        assertEq(_tokenA.balanceOf(address(this)), 0);
        assertEq(_tokenB.balanceOf(address(this)), 0);
        assertEq(_manager.getBalance(address(_pair), lToken0), 20e18);
        assertEq(_manager.getBalance(address(_pair), lToken1), 20e18);

        // act
        _manager.adjustBalance(address(_pair), lToken0, 19e18); // 1e18 lost
        _manager.adjustBalance(address(_pair), lToken1, 19e18); // 1e18 lost
        _pair.transfer(address(_pair), 10e18);
        _pair.burn(address(this));

        assertEq(_manager.getBalance(address(_pair), lToken0), 19e18);
        assertEq(_manager.getBalance(address(_pair), lToken1), 19e18);
        assertLt(_tokenA.balanceOf(address(this)), 10e18);
        assertLt(_tokenB.balanceOf(address(this)), 10e18);
    }
}
