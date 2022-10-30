pragma solidity 0.8.13;

import "test/__fixtures/BaseTest.sol";
import { stdStorage } from "forge-std/Test.sol";

import { IERC20 } from "@openzeppelin/token/ERC20/IERC20.sol";

import { MintableERC20 } from "test/__fixtures/MintableERC20.sol";
import { AssetManager } from "test/__mocks/AssetManager.sol";

import { Math } from "src/libraries/Math.sol";
import { ConstantProductOracleMath } from "src/libraries/ConstantProductOracleMath.sol";
import { LogCompression } from "src/libraries/LogCompression.sol";
import { IAssetManager } from "src/interfaces/IAssetManager.sol";
import { GenericFactory } from "src/GenericFactory.sol";
import { ConstantProductPair } from "src/curve/constant-product/ConstantProductPair.sol";

contract ConstantProductPairTest is BaseTest
{
    using stdStorage for StdStorage;

    event Burn(address indexed sender, uint256 amount0, uint256 amount1);

    AssetManager private _manager = new AssetManager();

    function _calculateOutput(
        uint256 aReserveIn,
        uint256 aReserveOut,
        uint256 aAmountIn,
        uint256 aFee
    ) private view returns (uint256 rExpectedOut)
    {
        uint256 lMaxFee = _constantProductPair.FEE_ACCURACY();
        uint256 lAmountInWithFee = aAmountIn * (lMaxFee - aFee);
        uint256 lNumerator = lAmountInWithFee * aReserveOut;
        uint256 lDenominator = aReserveIn * lMaxFee + lAmountInWithFee;

        rExpectedOut = lNumerator / lDenominator;
    }

    function _calculateInput(
        uint256 aReserveIn,
        uint256 aReserveOut,
        uint256 aAmountOut,
        uint256 aFee
    ) private view returns (uint256 rExpectedIn)
    {
        uint256 lMaxFee = _constantProductPair.FEE_ACCURACY();
        uint256 lNumerator = aReserveIn * aAmountOut * lMaxFee;
        uint256 lDenominator = (aReserveOut - aAmountOut) * (lMaxFee - aFee);
        rExpectedIn = lNumerator / lDenominator + 1;
    }

    function _getToken0Token1(address aTokenA, address aTokenB) private pure returns (address rToken0, address rToken1)
    {
        (rToken0, rToken1) = aTokenA < aTokenB ? (aTokenA, aTokenB) : (aTokenB, aTokenA);
    }

    function testMint() public
    {
        // arrange
        uint256 lTotalSupplyLpToken = _constantProductPair.totalSupply();
        uint256 lLiquidityToAdd = 5e18;
        (uint256 reserve0, , ) = _constantProductPair.getReserves();

        // act
        _tokenA.mint(address(_constantProductPair), lLiquidityToAdd);
        _tokenB.mint(address(_constantProductPair), lLiquidityToAdd);
        _constantProductPair.mint(address(this));

        // assert
        uint256 lAdditionalLpTokens = lLiquidityToAdd * lTotalSupplyLpToken / reserve0;
        assertEq(_constantProductPair.balanceOf(address(this)), lAdditionalLpTokens);
    }

    function testMint_InitialMint() public
    {
        // assert
        uint256 lpTokenBalance = _constantProductPair.balanceOf(_alice);
        uint256 lExpectedLpTokenBalance = Math.sqrt(INITIAL_MINT_AMOUNT ** 2) - _constantProductPair.MINIMUM_LIQUIDITY();
        assertEq(lpTokenBalance, lExpectedLpTokenBalance);
    }

    function testMint_JustAboveMinimumLiquidity() public
    {
        // arrange
        ConstantProductPair lPair = ConstantProductPair(_createPair(address(_tokenA), address(_tokenC), 0));

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
        ConstantProductPair lPair = ConstantProductPair(_createPair(address(_tokenA), address(_tokenC), 0));
        _tokenA.mint(address(lPair), 1000);
        _tokenC.mint(address(lPair), 1000);

        // act & assert
        vm.expectRevert("CP: INSUFFICIENT_LIQ_MINTED");
        lPair.mint(address(this));
    }

    function testMint_UnderMinimumLiquidity() public
    {
        // arrange
        ConstantProductPair lPair = ConstantProductPair(_createPair(address(_tokenA), address(_tokenC), 0));
        _tokenA.mint(address(lPair), 10);
        _tokenB.mint(address(lPair), 10);

        // act & assert
        vm.expectRevert(stdError.arithmeticError);
        lPair.mint(address(this));
    }

    function testSwap() public
    {
        // arrange
        (uint256 reserve0, uint256 reserve1, ) = _constantProductPair.getReserves();
        uint256 expectedOutput = _calculateOutput(reserve0, reserve1, 1e18, DEFAULT_SWAP_FEE_CP);

        // act
        address token0;
        address token1;
        (token0, token1) = _getToken0Token1(address(_tokenA), address(_tokenB));

        MintableERC20(token0).mint(address(_constantProductPair), 1e18);
        _constantProductPair.swap(1e18, true, address(this), "");

        // assert
        assertEq(MintableERC20(token1).balanceOf(address(this)), expectedOutput);
        assertEq(MintableERC20(token0).balanceOf(address(this)), 0);
    }

    function testSwap_ExtremeAmounts() public
    {
        // arrange
        ConstantProductPair lPair = ConstantProductPair(_createPair(address(_tokenB), address(_tokenC), 0));
        uint256 lSwapAmount = 1e18;
        uint256 lAmountB = type(uint112).max - lSwapAmount;
        uint256 lAmountC = type(uint112).max;
        _tokenB.mint(address(lPair), lAmountB);
        _tokenC.mint(address(lPair), lAmountC);
        lPair.mint(address(this));

        // act
        _tokenB.mint(address(lPair), lSwapAmount);
        lPair.swap(int256(lSwapAmount), true, address(this), bytes(""));

        // assert
        assertEq(_tokenC.balanceOf(address(this)), 0.997e18);
        assertEq(_tokenB.balanceOf(address(lPair)), type(uint112).max);
    }

    function testSwap_ExactOutExceedReserves() public
    {
        // act & assert
        vm.expectRevert("CP: NOT_ENOUGH_LIQ");
        _constantProductPair.swap(int256(INITIAL_MINT_AMOUNT), false, address(this), bytes(""));

        vm.expectRevert("CP: NOT_ENOUGH_LIQ");
        _constantProductPair.swap(int256(INITIAL_MINT_AMOUNT + 1), false, address(this), bytes(""));

        vm.expectRevert("CP: NOT_ENOUGH_LIQ");
        _constantProductPair.swap(-int256(INITIAL_MINT_AMOUNT), false, address(this), bytes(""));

        vm.expectRevert("CP: NOT_ENOUGH_LIQ");
        _constantProductPair.swap(-int256(INITIAL_MINT_AMOUNT + 1), false, address(this), bytes(""));
    }

    function testSwap_ExactOut(uint256 aAmountOut) public
    {
        // assume
        uint256 lMinNewReservesOut = INITIAL_MINT_AMOUNT ** 2 / type(uint112).max + 1;
        // this amount makes the new reserve of the input token stay within uint112 and not overflow
        uint256 lMaxOutputAmt = INITIAL_MINT_AMOUNT - lMinNewReservesOut;
        uint256 lAmountOut = bound(aAmountOut, 1, lMaxOutputAmt);

        // arrange
        vm.prank(address(_factory));
        _constantProductPair.setCustomSwapFee(0);
        (uint256 lReserve0, uint256 lReserve1, ) = _constantProductPair.getReserves();
        uint256 lAmountIn = _calculateInput(lReserve0, lReserve1, lAmountOut, _constantProductPair.swapFee());

        // act - exact token1 out
        _tokenA.mint(address(_constantProductPair), lAmountIn);
        uint256 lActualAmountOut = _constantProductPair.swap(-int256(lAmountOut), false, address(this), bytes(""));

        // assert
        assertGt(lAmountIn, lAmountOut);
        assertEq(lActualAmountOut, lAmountOut);
        assertEq(_tokenB.balanceOf(address(this)), lAmountOut);
    }

    function testSwap_ExactOut_NewReservesExceedUint112() public
    {
        // arrange
        vm.prank(address(_factory));
        _constantProductPair.setCustomSwapFee(0);
        uint256 lMinNewReservesOut = INITIAL_MINT_AMOUNT ** 2 / type(uint112).max + 1;
        uint256 lMaxOutputAmt = INITIAL_MINT_AMOUNT - lMinNewReservesOut;
        // 1 more than the max
        uint256 lAmountOut = lMaxOutputAmt + 1;
        (uint256 lReserve0, uint256 lReserve1, ) = _constantProductPair.getReserves();
        uint256 lAmountIn = _calculateInput(lReserve0, lReserve1, lAmountOut, _constantProductPair.swapFee());

        // act & assert
        _tokenA.mint(address(_constantProductPair), lAmountIn);
        vm.expectRevert("CP: OVERFLOW");
        _constantProductPair.swap(-int256(lAmountOut), false, address(this), bytes(""));
    }

    function testBurn() public
    {
        // arrange
        vm.startPrank(_alice);
        uint256 lLpTokenBalance = _constantProductPair.balanceOf(_alice);
        uint256 lLpTokenTotalSupply = _constantProductPair.totalSupply();
        (uint256 lReserve0, uint256 lReserve1, ) = _constantProductPair.getReserves();

        // act
        _constantProductPair.transfer(address(_constantProductPair), _constantProductPair.balanceOf(_alice));
        _constantProductPair.burn(_alice);

        // assert
        assertEq(_constantProductPair.balanceOf(_alice), 0);
        (address lToken0, address lToken1) = _getToken0Token1(address(_tokenA), address(_tokenB));
        assertEq(ConstantProductPair(lToken0).balanceOf(_alice), lLpTokenBalance * lReserve0 / lLpTokenTotalSupply);
        assertEq(ConstantProductPair(lToken1).balanceOf(_alice), lLpTokenBalance * lReserve1 / lLpTokenTotalSupply);
    }

    function testBurn_Zero() public
    {
        // act
        vm.expectEmit(true, true, true, true);
        emit Burn(address(this), 0, 0);
        _constantProductPair.burn(address(this));

        // assert
        assertEq(_tokenA.balanceOf(address(this)), 0);
        assertEq(_tokenB.balanceOf(address(this)), 0);
        assertEq(_tokenA.balanceOf(address(_constantProductPair)), INITIAL_MINT_AMOUNT);
        assertEq(_tokenB.balanceOf(address(_constantProductPair)), INITIAL_MINT_AMOUNT);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    ORACLE
    //////////////////////////////////////////////////////////////////////////*/

    function testOracle_NoWriteInSameTimestamp() public
    {
        // arrange
        uint16 lInitialIndex = _constantProductPair.index();
        uint256 lAmountToSwap = 1e17;

        // act
        _tokenA.mint(address(_constantProductPair), lAmountToSwap);
        _constantProductPair.swap(int256(lAmountToSwap), true, address(this), "");

        vm.prank(_alice);
        _constantProductPair.transfer(address(_constantProductPair), 1e18);
        _constantProductPair.burn(address(this));

        _constantProductPair.sync();

        // assert
        uint16 lFinalIndex = _constantProductPair.index();
        assertEq(lFinalIndex, lInitialIndex);
    }

    function testOracle_WrapsAroundAfterFull() public
    {
        // arrange
        uint256 lAmountToSwap = 1e17;
        uint256 lMaxObservations = 2 ** 16;

        // act
        for (uint i = 0; i < lMaxObservations + 4; ++i) {
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 5);
            _tokenA.mint(address(_constantProductPair), lAmountToSwap);
            _constantProductPair.swap(int256(lAmountToSwap), true, address(this), "");
        }

        // assert
        assertEq(_constantProductPair.index(), 3);
    }

    function testWriteObservations() external
    {
        // arrange
        // swap 1
        _stepTime(1);
        _tokenA.mint(address(_constantProductPair), 1e17);
        _constantProductPair.swap(1e17, true, address(this), "");

        // swap 2
        _stepTime(1);
        _tokenA.mint(address(_constantProductPair), 1e17);
        _constantProductPair.swap(1e17, true, address(this), "");

        // sanity
        assertEq(_constantProductPair.index(), 1);

        (int112 lLogPriceAcc, int112 lLogLiqAcc, uint32 lTimestamp) = _constantProductPair.observations(0);
        assertTrue(lLogPriceAcc == 0);
        assertTrue(lLogLiqAcc != 0);
        assertTrue(lTimestamp != 0);

        (lLogPriceAcc, lLogLiqAcc, lTimestamp) = _constantProductPair.observations(1);
        assertTrue(lLogPriceAcc != 0);
        assertTrue(lLogLiqAcc != 0);
        assertTrue(lTimestamp != 0);

        // act
        _writeObservation(_constantProductPair, 0, int112(1337), int112(-1337), uint32(666));

        // assert
        (lLogPriceAcc, lLogLiqAcc, lTimestamp) = _constantProductPair.observations(0);
        assertEq(lLogPriceAcc, int112(1337));
        assertEq(lLogLiqAcc, int112(-1337));
        assertEq(lTimestamp, uint32(666));

        (lLogPriceAcc, lLogLiqAcc, lTimestamp) = _constantProductPair.observations(1);
        assertTrue(lLogPriceAcc != 0);
        assertTrue(lLogLiqAcc != 0);
        assertTrue(lTimestamp != 0);
    }

    function testOracle_OverflowAccPrice() public
    {
        // arrange - make the last observation close to overflowing
        _writeObservation(
            _constantProductPair,
            _constantProductPair.index(),
            type(int112).max,
            0,
            uint32(block.timestamp)
        );
        (int112 lPrevAccPrice, , ) = _constantProductPair.observations(_constantProductPair.index());

        // act
        uint256 lAmountToSwap = 1e18;
        _tokenB.mint(address(_constantProductPair), lAmountToSwap);
        _constantProductPair.swap(-int256(lAmountToSwap), true, address(this), "");

        _stepTime(5);
        _constantProductPair.sync();

        // assert - when it overflows it goes from a very positive number to a very negative number
        (int112 lCurrAccPrice, , ) = _constantProductPair.observations(_constantProductPair.index());
        assertLt(lCurrAccPrice, lPrevAccPrice);
    }

    function testOracle_OverflowAccLiquidity() public
    {
        // arrange
        _writeObservation(
            _constantProductPair,
            _constantProductPair.index(),
            0,
            type(int112).max,
            uint32(block.timestamp)
        );
        (, int112 lPrevAccLiq, ) = _constantProductPair.observations(_constantProductPair.index());

        // act
        _stepTime(5);
        _constantProductPair.sync();

        // assert
        (, int112 lCurrAccLiq, ) = _constantProductPair.observations(_constantProductPair.index());
        assertLt(lCurrAccLiq, lPrevAccLiq);
    }

    function testOracle_CorrectPrice() public
    {
        // arrange
        uint256 lAmountToSwap = 1e18;
        _stepTime(5);

        // act
        _tokenA.mint(address(_constantProductPair), lAmountToSwap);
        _constantProductPair.swap(int256(lAmountToSwap), true, address(this), "");

        (uint256 lReserve0_1, uint256 lReserve1_1, ) = _constantProductPair.getReserves();
        uint256 lPrice1 = lReserve1_1 * 1e18 / lReserve0_1;
        _stepTime(5);

        _tokenA.mint(address(_constantProductPair), lAmountToSwap);
        _constantProductPair.swap(int256(lAmountToSwap), true, address(this), "");
        (uint256 lReserve0_2, uint256 lReserve1_2, ) = _constantProductPair.getReserves();
        uint256 lPrice2 = lReserve1_2 * 1e18 / lReserve0_2;

        _stepTime(5);
        _constantProductPair.sync();

        // assert
        (int lAccPrice1, , uint32 lTimestamp1) = _constantProductPair.observations(0);
        (int lAccPrice2, , uint32 lTimestamp2) = _constantProductPair.observations(1);
        (int lAccPrice3, , uint32 lTimestamp3) = _constantProductPair.observations(2);

        assertApproxEqRel(
            LogCompression.fromLowResLog((lAccPrice2 - lAccPrice1) / int32(lTimestamp2 - lTimestamp1)),
            lPrice1,
            0.0001e18
        );
        assertApproxEqRel(
            LogCompression.fromLowResLog((lAccPrice3 - lAccPrice1) / int32(lTimestamp3 - lTimestamp1)),
            Math.sqrt(lPrice1 * lPrice2),
            0.0001e18
        );
    }

    function testOracle_CorrectPriceDiffDecimals() public
    {
        // arrange
        ConstantProductPair lPair = ConstantProductPair(_createPair(address(_tokenA), address(_tokenD), 0));
        _tokenA.mint(address(lPair), 100e18);
        _tokenD.mint(address(lPair), 50e6);
        lPair.mint(address(this));

        // act
        _stepTime(5);
        lPair.sync();

        // assert
        (int112 accLogPrice, ,) = lPair.observations(0);
        assertApproxEqRel(LogCompression.fromLowResLog(accLogPrice / 5), 0.5e18, 0.0001e18);
    }

    function testOracle_SimplePrices() external
    {
        // prices = [1, 4, 16]
        // geo_mean = sqrt3(1 * 4 * 16) = 4

        // arrange
        vm.prank(address(_factory));
        _constantProductPair.setCustomSwapFee(0);

        // price = 1
        _stepTime(10);

        // act
        // price = 4
        _tokenA.mint(address(_constantProductPair), 100e18);
        _constantProductPair.swap(100e18, true, _bob, "");
        _stepTime(10);

        // price = 16
        _tokenA.mint(address(_constantProductPair), 200e18);
        _constantProductPair.swap(200e18, true, _bob, "");
        _stepTime(10);
        _constantProductPair.sync();

        // assert
        (int lAccPrice1, , uint32 lTimestamp1) = _constantProductPair.observations(0);
        (int lAccPrice2, , uint32 lTimestamp2) = _constantProductPair.observations(1);
        (int lAccPrice3, , uint32 lTimestamp3) = _constantProductPair.observations(2);

        assertEq(lAccPrice1, LogCompression.toLowResLog(1e18) * 10, "1");
        assertEq(lAccPrice2, LogCompression.toLowResLog(1e18) * 10 + LogCompression.toLowResLog(0.25e18) * 10, "2");
        assertEq(
            lAccPrice3,
            LogCompression.toLowResLog(1e18) * 10
            + LogCompression.toLowResLog(0.25e18) * 10
            + LogCompression.toLowResLog(0.0625e18) * 10,
            "3"
        );

        // Price for observation window 1-2
        assertApproxEqRel(
            LogCompression.fromLowResLog((lAccPrice2 - lAccPrice1) / int32(lTimestamp2 - lTimestamp1)),
            0.25e18,
            0.0001e18
        );
        // Price for observation window 2-3
        assertApproxEqRel(
            LogCompression.fromLowResLog((lAccPrice3 - lAccPrice2) / int32(lTimestamp3 - lTimestamp2)),
            0.0625e18,
            0.0001e18
        );
        // Price for observation window 1-3
        assertApproxEqRel(
            LogCompression.fromLowResLog((lAccPrice3 - lAccPrice1) / int32(lTimestamp3 - lTimestamp1)),
            0.125e18,
            0.0001e18
        );
    }

    function testOracle_CorrectLiquidity() public
    {
        // arrange
        uint256 lAmountToBurn = 1e18;

        // act
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 5);
        vm.prank(_alice);
        _constantProductPair.transfer(address(_constantProductPair), lAmountToBurn);
        _constantProductPair.burn(address(this));

        // assert
        (, int256 lAccLiq, ) = _constantProductPair.observations(_constantProductPair.index());
        uint256 lAverageLiq = LogCompression.fromLowResLog(lAccLiq / 5);
        // we check that it is within 0.01% of accuracy
        assertApproxEqRel(lAverageLiq, INITIAL_MINT_AMOUNT, 0.0001e18);

        // act
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 5);
        _constantProductPair.sync();

        // assert
        (, int256 lAccLiq2, ) = _constantProductPair.observations(_constantProductPair.index());
        uint256 lAverageLiq2 = LogCompression.fromLowResLog((lAccLiq2 - lAccLiq) / 5);
        assertApproxEqRel(lAverageLiq2, 99e18, 0.0001e18);
    }

    function testOracle_LiquidityAtMaximum() public
    {
        // arrange
        uint256 lLiquidityToAdd = type(uint112).max - INITIAL_MINT_AMOUNT;
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 5);
        _tokenA.mint(address(_constantProductPair), lLiquidityToAdd);
        _tokenB.mint(address(_constantProductPair), lLiquidityToAdd);
        _constantProductPair.mint(address(this));

        // sanity
        (uint112 lReserve0, uint112 lReserve1, ) = _constantProductPair.getReserves();
        assertEq(lReserve0, type(uint112).max);
        assertEq(lReserve1, type(uint112).max);

        // act
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 5);
        _constantProductPair.sync();

        // assert
        uint256 lTotalSupply = _constantProductPair.totalSupply();
        assertEq(lTotalSupply, type(uint112).max);

        (, int112 lAccLiq1, ) = _constantProductPair.observations(0);
        (, int112 lAccLiq2, ) = _constantProductPair.observations(_constantProductPair.index());
        assertApproxEqRel(type(uint112).max, LogCompression.fromLowResLog( (lAccLiq2 - lAccLiq1) / 5), 0.0001e18);
    }
}
