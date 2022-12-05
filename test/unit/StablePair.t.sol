pragma solidity ^0.8.0;

import "test/__fixtures/BaseTest.sol";
import "test/__fixtures/MintableERC20.sol";

import { Math } from "src/libraries/Math.sol";
import { MathUtils } from "src/libraries/MathUtils.sol";
import { LogCompression } from "src/libraries/LogCompression.sol";
import { StableOracleMath } from "src/libraries/StableOracleMath.sol";
import { StableMath } from "src/libraries/StableMath.sol";
import { Observation } from "src/interfaces/IOracleWriter.sol";
import { StablePair, AmplificationData } from "src/curve/stable/StablePair.sol";
import { GenericFactory } from "src/GenericFactory.sol";

contract StablePairTest is BaseTest {
    using FactoryStoreLib for GenericFactory;

    event RampA(uint64 initialA, uint64 futureA, uint64 initialTime, uint64 futureTime);
    event Burn(address indexed sender, uint amount0, uint amount1);

    function _calculateConstantProductOutput(uint aReserveIn, uint aReserveOut, uint aTokenIn, uint aFee)
        private
        view
        returns (uint rExpectedOut)
    {
        uint MAX_FEE = _constantProductPair.FEE_ACCURACY();
        uint lAmountInWithFee = aTokenIn * (MAX_FEE - aFee);
        uint lNumerator = lAmountInWithFee * aReserveOut;
        uint lDenominator = aReserveIn * MAX_FEE + lAmountInWithFee;

        rExpectedOut = lNumerator / lDenominator;
    }

    function testFactoryAmpTooLow() public {
        // arrange
        _factory.write("SP::amplificationCoefficient", StableMath.MIN_A - 1);

        // act & assert
        vm.expectRevert("FACTORY: DEPLOY_FAILED");
        _createPair(address(_tokenC), address(_tokenD), 1);
    }

    function testFactoryAmpTooHigh() public {
        // arrange
        _factory.write("SP::amplificationCoefficient", StableMath.MAX_A + 1);

        // act & assert
        vm.expectRevert("FACTORY: DEPLOY_FAILED");
        _createPair(address(_tokenC), address(_tokenD), 1);
    }

    function testMint() public {
        // arrange
        uint lLpTokenTotalSupply = _stablePair.totalSupply();
        (uint lReserve0, uint lReserve1,) = _stablePair.getReserves();
        uint lOldLiquidity = lReserve0 + lReserve1;
        uint lLiquidityToAdd = 5e18;

        // act
        _tokenA.mint(address(_stablePair), lLiquidityToAdd);
        _tokenB.mint(address(_stablePair), lLiquidityToAdd);
        _stablePair.mint(address(this));

        // assert
        // this works only because the pools are balanced. When the pool is imbalanced the calculation will differ
        uint lAdditionalLpTokens =
            ((INITIAL_MINT_AMOUNT + lLiquidityToAdd) * 2 - lOldLiquidity) * lLpTokenTotalSupply / lOldLiquidity;
        assertEq(_stablePair.balanceOf(address(this)), lAdditionalLpTokens);
    }

    function testMint_OnlyTransferOneToken() public {
        // arrange
        StablePair lPair = StablePair(_createPair(address(_tokenA), address(_tokenC), 1));
        _tokenA.mint(address(lPair), 5e18);

        // act & assert
        vm.expectRevert(stdError.divisionError);
        lPair.mint(address(this));
    }

    function testMint_NonOptimalProportion() public {
        // arrange
        uint lAmountAToMint = 1e18;
        uint lAmountBToMint = 100e18;

        _tokenA.mint(address(_stablePair), lAmountAToMint);
        _tokenB.mint(address(_stablePair), lAmountBToMint);

        // act
        _stablePair.mint(address(this));

        // assert
        assertLt(_stablePair.balanceOf(address(this)), lAmountAToMint + lAmountBToMint);
        assertGt(_stablePair.getVirtualPrice(), 1e18);
    }

    // This test case demonstrates that if a LP provider provides liquidity in non-optimal proportions
    // and then removes liquidity, they would be worse off had they just swapped it instead
    // and thus the mint-burn mechanism cannot be gamed into getting a better price
    function testMint_NonOptimalProportion_ThenBurn() public {
        // arrange
        uint lBefore = vm.snapshot();
        uint lAmountAToMint = 1e18;
        uint lAmountBToMint = 100e18;

        _tokenA.mint(address(_stablePair), lAmountAToMint);
        _tokenB.mint(address(_stablePair), lAmountBToMint);

        // act
        _stablePair.mint(address(this));
        _stablePair.transfer(address(_stablePair), _stablePair.balanceOf(address(this)));
        _stablePair.burn(address(this));

        uint lBurnOutputA = _tokenA.balanceOf(address(this));
        uint lBurnOutputB = _tokenB.balanceOf(address(this));

        vm.revertTo(lBefore);

        // swap
        uint lAmountToSwap = lAmountBToMint - lBurnOutputB;
        _tokenB.mint(address(_stablePair), lAmountToSwap);
        _stablePair.swap(-int(lAmountToSwap), true, address(this), bytes(""));

        uint lSwapOutputA = _tokenA.balanceOf(address(this));

        // assert
        assertLt(lBurnOutputA, lSwapOutputA + lAmountAToMint);
    }

    function testMintFee_WhenRampingA_PoolBalanced(uint aFutureA) public {
        // assume - for ramping up or down from DEFAULT_AMP_COEFF
        uint64 lFutureAToSet = uint64(bound(aFutureA, 100, 5000));
        vm.assume(lFutureAToSet != DEFAULT_AMP_COEFF);

        // arrange
        StablePair lOtherPair = StablePair(_createPair(address(_tokenA), address(_tokenC), 1));
        _tokenA.mint(address(lOtherPair), INITIAL_MINT_AMOUNT);
        _tokenC.mint(address(lOtherPair), INITIAL_MINT_AMOUNT);
        lOtherPair.mint(_alice);

        for (uint i = 0; i < 10; ++i) {
            uint lAmountToSwap = 5e18;

            _tokenA.mint(address(_stablePair), lAmountToSwap);
            _stablePair.swap(int(lAmountToSwap), true, address(this), bytes(""));

            _tokenB.mint(address(_stablePair), lAmountToSwap);
            _stablePair.swap(-int(lAmountToSwap), true, address(this), bytes(""));

            _tokenA.mint(address(lOtherPair), lAmountToSwap);
            lOtherPair.swap(int(lAmountToSwap), true, address(this), bytes(""));

            _tokenC.mint(address(lOtherPair), lAmountToSwap);
            lOtherPair.swap(-int(lAmountToSwap), true, address(this), bytes(""));
        }

        // we change A for _stablePair but not for lOtherPair
        uint64 lCurrentTimestamp = uint64(block.timestamp);
        uint64 lFutureATimestamp = lCurrentTimestamp + 5 days;

        _factory.rawCall(
            address(_stablePair), abi.encodeWithSignature("rampA(uint64,uint64)", lFutureAToSet, lFutureATimestamp), 0
        );

        // sanity
        assertEq(_stablePair.getCurrentA(), lOtherPair.getCurrentA());

        // act - warp to the end
        vm.warp(lFutureATimestamp);
        assertEq(_stablePair.getCurrentA(), lFutureAToSet);
        assertTrue(_stablePair.getCurrentA() != lOtherPair.getCurrentA());

        // sanity
        (uint lReserve0_S, uint lReserve1_S,) = _stablePair.getReserves();
        (uint lReserve0_O, uint lReserve1_O,) = lOtherPair.getReserves();
        assertEq(lReserve0_S, lReserve0_O);
        assertEq(lReserve1_S, lReserve1_O);

        (uint lTotalSupply1,) = _stablePair.burn(address(this));
        (uint lTotalSupply2,) = lOtherPair.burn(address(this));

        // assert - even after the difference in A, we expect the platformFee received (LP tokens) to be the same
        assertEq(_stablePair.balanceOf(address(_platformFeeTo)), lOtherPair.balanceOf(address(_platformFeeTo)));
        assertEq(lTotalSupply1, lTotalSupply2);
    }

    function testMintFee_WhenRampingA_PoolUnbalanced(uint aFutureA) public {
        // assume - for ramping up or down from DEFAULT_AMP_COEFF
        uint64 lFutureAToSet = uint64(bound(aFutureA, 100, 5000));
        vm.assume(lFutureAToSet != DEFAULT_AMP_COEFF);

        // arrange
        StablePair lOtherPair = StablePair(_createPair(address(_tokenA), address(_tokenC), 1));
        _tokenA.mint(address(lOtherPair), INITIAL_MINT_AMOUNT);
        _tokenC.mint(address(lOtherPair), INITIAL_MINT_AMOUNT);
        lOtherPair.mint(_alice);

        for (uint i = 0; i < 10; ++i) {
            uint lAmountToSwap = 5e18;

            _tokenA.mint(address(_stablePair), lAmountToSwap);
            _stablePair.swap(int(lAmountToSwap), true, address(this), bytes(""));

            _tokenA.mint(address(lOtherPair), lAmountToSwap);
            lOtherPair.swap(int(lAmountToSwap), true, address(this), bytes(""));
        }

        // we change A for _stablePair but not for lOtherPair
        uint64 lCurrentTimestamp = uint64(block.timestamp);
        uint64 lFutureATimestamp = lCurrentTimestamp + 5 days;

        _factory.rawCall(
            address(_stablePair), abi.encodeWithSignature("rampA(uint64,uint64)", lFutureAToSet, lFutureATimestamp), 0
        );

        // sanity
        assertEq(_stablePair.getCurrentA(), lOtherPair.getCurrentA());

        // act - warp to the end
        vm.warp(lFutureATimestamp);
        assertEq(_stablePair.getCurrentA(), lFutureAToSet);
        assertTrue(_stablePair.getCurrentA() != lOtherPair.getCurrentA());

        // sanity
        (uint lReserve0_S, uint lReserve1_S,) = _stablePair.getReserves();
        (uint lReserve0_O, uint lReserve1_O,) = lOtherPair.getReserves();
        assertEq(lReserve0_S, lReserve0_O);
        assertEq(lReserve1_S, lReserve1_O);

        (uint lTotalSupply1,) = _stablePair.burn(address(this));
        (uint lTotalSupply2,) = lOtherPair.burn(address(this));

        // assert - even after the difference in A, we expect the platformFee received (LP tokens) to be the same
        assertEq(_stablePair.balanceOf(address(_platformFeeTo)), lOtherPair.balanceOf(address(_platformFeeTo)));
        assertEq(lTotalSupply1, lTotalSupply2);
    }

    function _calcExpectedPlatformFee(
        uint aPlatformFee,
        StablePair aPair,
        uint aReserve0,
        uint aReserve1,
        uint aTotalSupply,
        uint aOldLiq
    ) internal view returns (uint rExpectedPlatformFee, uint rGrowthInLiq) {
        (uint lReserveC, uint lReserveD) =
            aPair.token0() == address(_tokenC) ? (aReserve0, aReserve1) : (aReserve1, aReserve0);
        uint lNewLiq = StableMath._computeLiquidityFromAdjustedBalances(
            lReserveD * 1e12, lReserveC, 2 * aPair.getCurrentAPrecise()
        );

        rGrowthInLiq = lNewLiq - aOldLiq;
        rExpectedPlatformFee = aTotalSupply * rGrowthInLiq * aPlatformFee
            / ((aPair.FEE_ACCURACY() - aPlatformFee) * lNewLiq + aPlatformFee * aOldLiq);
    }

    function testMintFee_DiffPlatformFees(uint aPlatformFee) public {
        // assume
        uint lPlatformFee = bound(aPlatformFee, 0, _stablePair.MAX_PLATFORM_FEE());

        // arrange
        StablePair lPair = StablePair(_createPair(address(_tokenC), address(_tokenD), 1));
        vm.prank(address(_factory));
        lPair.setCustomPlatformFee(lPlatformFee);
        _tokenC.mint(address(lPair), 100_000_000e18);
        _tokenD.mint(address(lPair), 120_000_000e6);
        lPair.mint(address(this));
        uint lOldLiq = StableMath._computeLiquidityFromAdjustedBalances(
            120_000_000e6 * 1e12, 100_000_000e18, 2 * lPair.getCurrentAPrecise()
        );

        uint lCSwapAmt = 11_301_493e18;
        uint lDSwapAmt = 10_402_183e6;

        // sanity
        assertEq(lPair.platformFee(), lPlatformFee);

        // increase liq by swapping back and forth
        for (uint i; i < 20; ++i) {
            _tokenD.mint(address(lPair), lDSwapAmt);
            lPair.swap(
                lPair.token0() == address(_tokenD) ? int(lDSwapAmt) : -int(lDSwapAmt), true, address(this), bytes("")
            );

            _tokenC.mint(address(lPair), lCSwapAmt);
            lPair.swap(
                lPair.token0() == address(_tokenC) ? int(lCSwapAmt) : -int(lCSwapAmt), true, address(this), bytes("")
            );
        }

        (uint lReserve0, uint lReserve1,) = lPair.getReserves();
        uint lTotalSupply = lPair.totalSupply();

        // act
        lPair.transfer(address(lPair), 1e18);
        lPair.burn(address(this));

        // assert
        (uint lExpectedPlatformFee, uint lGrowthInLiq) =
            _calcExpectedPlatformFee(lPlatformFee, lPair, lReserve0, lReserve1, lTotalSupply, lOldLiq);
        assertEq(lPair.balanceOf(_platformFeeTo), lExpectedPlatformFee);
        assertApproxEqRel(
            lExpectedPlatformFee * 1e18 / lGrowthInLiq, lPlatformFee * 1e18 / lPair.FEE_ACCURACY(), 0.006e18
        );
    }

    function testSwap() public {
        // act
        uint lAmountToSwap = 5e18;
        _tokenA.mint(address(_stablePair), lAmountToSwap);
        uint lAmountOut = _stablePair.swap(int(lAmountToSwap), true, address(this), "");

        // assert
        assertEq(lAmountOut, _tokenB.balanceOf(address(this)));
    }

    function testSwap_ZeroInput() public {
        // act & assert
        vm.expectRevert("SP: AMOUNT_ZERO");
        _stablePair.swap(0, true, address(this), "");
    }

    function testSwap_Token0ExactOut(uint aAmountOut) public {
        // assume
        uint lAmountOut = bound(aAmountOut, 1e6, INITIAL_MINT_AMOUNT - 1);

        // arrange
        (uint112 lReserve0, uint112 lReserve1,) = _stablePair.getReserves();
        uint lAmountIn = StableMath._getAmountIn(
            lAmountOut, lReserve0, lReserve1, 1, 1, true, DEFAULT_SWAP_FEE_SP, 2 * _stablePair.getCurrentAPrecise()
        );

        // sanity - given a balanced pool, the amountIn should be greater than amountOut
        assertGt(lAmountIn, lAmountOut);

        // act
        _tokenB.mint(address(_stablePair), lAmountIn);
        uint lActualOut = _stablePair.swap(int(lAmountOut), false, address(this), bytes(""));

        // assert
        uint inverse = StableMath._getAmountOut(
            lAmountIn, lReserve0, lReserve1, 1, 1, false, DEFAULT_SWAP_FEE_SP, 2 * _stablePair.getCurrentAPrecise()
        );
        // todo: investigate why it has this (small) difference of around (less than 1/10 of a basis point)
        assertApproxEqRel(inverse, lActualOut, 0.00001e18);
        assertEq(lActualOut, lAmountOut);
    }

    function testSwap_Token1ExactOut(uint aAmountOut) public {
        // assume
        uint lAmountOut = bound(aAmountOut, 1e6, INITIAL_MINT_AMOUNT - 1);

        // arrange
        (uint112 lReserve0, uint112 lReserve1,) = _stablePair.getReserves();
        uint lAmountIn = StableMath._getAmountIn(
            lAmountOut, lReserve0, lReserve1, 1, 1, false, DEFAULT_SWAP_FEE_SP, 2 * _stablePair.getCurrentAPrecise()
        );

        // sanity - given a balanced pool, the amountIn should be greater than amountOut
        assertGt(lAmountIn, lAmountOut);

        // act
        _tokenA.mint(address(_stablePair), lAmountIn);
        uint lActualOut = _stablePair.swap(-int(lAmountOut), false, address(this), bytes(""));

        // assert
        uint inverse = StableMath._getAmountOut(
            lAmountIn, lReserve0, lReserve1, 1, 1, true, DEFAULT_SWAP_FEE_SP, 2 * _stablePair.getCurrentAPrecise()
        );
        // todo: investigate why it has this (small) difference of around (less than 1/10 of a basis point)
        assertApproxEqRel(inverse, lActualOut, 0.00001e18);
        assertEq(lActualOut, lAmountOut);
    }

    function testSwap_ExactOutExceedReserves() public {
        // act & assert
        vm.expectRevert("SP: NOT_ENOUGH_LIQ");
        _stablePair.swap(int(INITIAL_MINT_AMOUNT), false, address(this), bytes(""));

        vm.expectRevert("SP: NOT_ENOUGH_LIQ");
        _stablePair.swap(int(INITIAL_MINT_AMOUNT + 1), false, address(this), bytes(""));

        vm.expectRevert("SP: NOT_ENOUGH_LIQ");
        _stablePair.swap(-int(INITIAL_MINT_AMOUNT), false, address(this), bytes(""));

        vm.expectRevert("SP: NOT_ENOUGH_LIQ");
        _stablePair.swap(-int(INITIAL_MINT_AMOUNT + 1), false, address(this), bytes(""));
    }

    function testSwap_BetterPerformanceThanConstantProduct() public {
        // act
        uint lSwapAmount = 5e18;
        _tokenA.mint(address(_stablePair), lSwapAmount);
        _stablePair.swap(int(lSwapAmount), true, address(this), "");
        uint lStablePairOutput = _tokenB.balanceOf(address(this));

        _tokenA.mint(address(_constantProductPair), lSwapAmount);
        _constantProductPair.swap(int(lSwapAmount), true, address(this), "");
        uint lConstantProductOutput = _tokenB.balanceOf(address(this)) - lStablePairOutput;

        // assert
        assertGt(lStablePairOutput, lConstantProductOutput);
    }

    function testSwap_VerySmallLiquidity(uint aAmtBToMint, uint aAmtCToMint, uint aSwapAmt) public {
        // assume
        uint lMinLiq = _stablePair.MINIMUM_LIQUIDITY();
        uint lAmtBToMint = bound(aAmtBToMint, lMinLiq / 2 + 1, lMinLiq);
        uint lAmtCToMint = bound(aAmtCToMint, lMinLiq / 2 + 1, lMinLiq);
        uint lSwapAmt = bound(aSwapAmt, 1, type(uint112).max - lAmtBToMint);

        // arrange
        StablePair lPair = StablePair(_createPair(address(_tokenB), address(_tokenC), 1));
        _tokenB.mint(address(lPair), lAmtBToMint);
        _tokenC.mint(address(lPair), lAmtCToMint);
        lPair.mint(address(this));

        // sanity
        assertGe(lPair.balanceOf(address(this)), 2);

        // act
        _tokenB.mint(address(lPair), lSwapAmt);
        uint lAmtOut = lPair.swap(
            lPair.token0() == address(_tokenB) ? int(lSwapAmt) : -int(lSwapAmt), true, address(this), bytes("")
        );

        // assert
        uint lExpectedAmountOut = StableMath._getAmountOut(
            lSwapAmt,
            lPair.token0() == address(_tokenB) ? lAmtBToMint : lAmtCToMint,
            lPair.token1() == address(_tokenB) ? lAmtBToMint : lAmtCToMint,
            1,
            1,
            lPair.token0() == address(_tokenB),
            DEFAULT_SWAP_FEE_SP,
            2 * _stablePair.getCurrentAPrecise()
        );
        assertEq(lAmtOut, lExpectedAmountOut);
    }

    function testSwap_VeryLargeLiquidity(uint aSwapAmt) public {
        // assume
        uint lSwapAmt = bound(aSwapAmt, 1, 10e18);
        uint lAmtBToMint = type(uint112).max;
        uint lAmtCToMint = type(uint112).max - lSwapAmt;

        // arrange
        StablePair lPair = StablePair(_createPair(address(_tokenB), address(_tokenC), 1));
        _tokenB.mint(address(lPair), lAmtBToMint);
        _tokenC.mint(address(lPair), lAmtCToMint);
        lPair.mint(address(this));

        // act
        _tokenC.mint(address(lPair), lSwapAmt);
        uint lAmtOut = lPair.swap(
            lPair.token0() == address(_tokenC) ? int(lSwapAmt) : -int(lSwapAmt), true, address(this), bytes("")
        );

        // assert
        uint lExpectedAmountOut = StableMath._getAmountOut(
            lSwapAmt,
            lPair.token0() == address(_tokenB) ? lAmtBToMint : lAmtCToMint,
            lPair.token1() == address(_tokenB) ? lAmtBToMint : lAmtCToMint,
            1,
            1,
            lPair.token0() == address(_tokenC),
            DEFAULT_SWAP_FEE_SP,
            2 * _stablePair.getCurrentAPrecise()
        );
        assertEq(lAmtOut, lExpectedAmountOut);
    }

    function testSwap_DiffSwapFees(uint aSwapFee) public {
        // assume
        uint lSwapFee = bound(aSwapFee, 0, _stablePair.MAX_SWAP_FEE());

        // arrange
        StablePair lPair = StablePair(_createPair(address(_tokenC), address(_tokenD), 1));
        vm.prank(address(_factory));
        lPair.setCustomSwapFee(lSwapFee);
        uint lTokenCMintAmt = 100_000_000e18;
        uint lTokenDMintAmt = 120_000_000e6;
        _tokenC.mint(address(lPair), lTokenCMintAmt);
        _tokenD.mint(address(lPair), lTokenDMintAmt);
        lPair.mint(address(this));

        uint lSwapAmt = 10_000_000e6;
        _tokenD.mint(address(lPair), lSwapAmt);

        // act
        uint lAmtOut = lPair.swap(
            lPair.token0() == address(_tokenD) ? int(lSwapAmt) : -int(lSwapAmt), true, address(this), bytes("")
        );

        uint lExpectedAmtOut = StableMath._getAmountOut(
            lSwapAmt,
            lPair.token0() == address(_tokenD) ? lTokenDMintAmt : lTokenCMintAmt,
            lPair.token1() == address(_tokenD) ? lTokenDMintAmt : lTokenCMintAmt,
            lPair.token0() == address(_tokenD) ? 1e12 : 1,
            lPair.token1() == address(_tokenD) ? 1e12 : 1,
            lPair.token0() == address(_tokenD),
            lSwapFee,
            2 * lPair.getCurrentAPrecise()
        );

        // assert
        assertEq(lAmtOut, lExpectedAmtOut);
    }

    function testSwap_IncreasingSwapFees(uint aSwapFee0, uint aSwapFee1, uint aSwapFee2) public {
        // assume
        uint lSwapFee0 = bound(aSwapFee0, 0, _stablePair.MAX_SWAP_FEE() / 4); // between 0 - 0.5%
        uint lSwapFee1 = bound(aSwapFee1, _stablePair.MAX_SWAP_FEE() / 4 + 1, _stablePair.MAX_SWAP_FEE() / 2); // between
            // 0.5 - 1%
        uint lSwapFee2 = bound(aSwapFee2, _stablePair.MAX_SWAP_FEE() / 2 + 1, _stablePair.MAX_SWAP_FEE()); // between 1
            // - 2%

        // sanity
        assertGt(lSwapFee1, lSwapFee0);
        assertGt(lSwapFee2, lSwapFee1);

        // arrange
        uint lSwapAmt = 10e18;
        (uint lReserve0, uint lReserve1,) = _stablePair.getReserves();

        // act
        vm.prank(address(_factory));
        _stablePair.setCustomSwapFee(lSwapFee0);
        uint lBefore = vm.snapshot();

        uint lExpectedOut0 = StableMath._getAmountOut(
            lSwapAmt, lReserve0, lReserve1, 1, 1, true, lSwapFee0, 2 * _stablePair.getCurrentAPrecise()
        );
        _tokenA.mint(address(_stablePair), lSwapAmt);
        uint lActualOut = _stablePair.swap(int(lSwapAmt), true, address(this), bytes(""));
        assertEq(lExpectedOut0, lActualOut);

        vm.revertTo(lBefore);
        vm.prank(address(_factory));
        _stablePair.setCustomSwapFee(lSwapFee1);
        lBefore = vm.snapshot();

        uint lExpectedOut1 = StableMath._getAmountOut(
            lSwapAmt, lReserve0, lReserve1, 1, 1, true, lSwapFee1, 2 * _stablePair.getCurrentAPrecise()
        );
        _tokenA.mint(address(_stablePair), lSwapAmt);
        lActualOut = _stablePair.swap(int(lSwapAmt), true, address(this), bytes(""));
        assertEq(lExpectedOut1, lActualOut);

        vm.revertTo(lBefore);
        vm.prank(address(_factory));
        _stablePair.setCustomSwapFee(lSwapFee2);

        uint lExpectedOut2 = StableMath._getAmountOut(
            lSwapAmt, lReserve0, lReserve1, 1, 1, true, lSwapFee2, 2 * _stablePair.getCurrentAPrecise()
        );
        _tokenA.mint(address(_stablePair), lSwapAmt);
        lActualOut = _stablePair.swap(int(lSwapAmt), true, address(this), bytes(""));
        assertEq(lExpectedOut2, lActualOut);

        // assert
        assertLt(lExpectedOut1, lExpectedOut0);
        assertLt(lExpectedOut2, lExpectedOut1);
    }

    function testSwap_DiffAs(uint aAmpCoeff, uint aSwapAmt, uint aMintAmt) public {
        // assume
        uint lAmpCoeff = bound(aAmpCoeff, StableMath.MIN_A, StableMath.MAX_A);
        uint lSwapAmt = bound(aSwapAmt, 1e3, type(uint112).max / 2);
        uint lCMintAmt = bound(aMintAmt, 1e18, 10_000_000_000e18);
        uint lDMintAmt = bound(lCMintAmt, lCMintAmt / 1e12 / 1e3, lCMintAmt / 1e12 * 1e3);

        // arrange
        _factory.write("SP::amplificationCoefficient", lAmpCoeff);
        StablePair lPair = StablePair(_createPair(address(_tokenD), address(_tokenC), 1));

        // sanity
        assertEq(lPair.getCurrentA(), lAmpCoeff);

        _tokenC.mint(address(lPair), lCMintAmt);
        _tokenD.mint(address(lPair), lDMintAmt);
        lPair.mint(address(this));

        // act
        _tokenD.mint(address(lPair), lSwapAmt);
        lPair.swap(lPair.token0() == address(_tokenD) ? int(lSwapAmt) : -int(lSwapAmt), true, address(this), bytes(""));

        // assert
        uint lExpectedOutput = StableMath._getAmountOut(
            lSwapAmt,
            lPair.token0() == address(_tokenD) ? lDMintAmt : lCMintAmt,
            lPair.token1() == address(_tokenD) ? lDMintAmt : lCMintAmt,
            lPair.token0() == address(_tokenD) ? 1e12 : 1,
            lPair.token1() == address(_tokenD) ? 1e12 : 1,
            lPair.token0() == address(_tokenD),
            lPair.swapFee(),
            2 * lPair.getCurrentAPrecise()
        );
        assertEq(_tokenC.balanceOf(address(this)), lExpectedOutput);
    }

    function testBurn() public {
        // arrange
        vm.startPrank(_alice);
        uint lLpTokenBalance = _stablePair.balanceOf(_alice);
        uint lLpTokenTotalSupply = _stablePair.totalSupply();
        (uint lReserve0, uint lReserve1,) = _stablePair.getReserves();
        address lToken0 = _stablePair.token0();

        // act
        _stablePair.transfer(address(_stablePair), _stablePair.balanceOf(_alice));
        _stablePair.burn(_alice);

        // assert
        uint lExpectedTokenAReceived;
        uint lExpectedTokenBReceived;
        if (lToken0 == address(_tokenA)) {
            lExpectedTokenAReceived = lLpTokenBalance * lReserve0 / lLpTokenTotalSupply;
            lExpectedTokenBReceived = lLpTokenBalance * lReserve1 / lLpTokenTotalSupply;
        } else {
            lExpectedTokenAReceived = lLpTokenBalance * lReserve1 / lLpTokenTotalSupply;
            lExpectedTokenBReceived = lLpTokenBalance * lReserve0 / lLpTokenTotalSupply;
        }

        assertEq(_stablePair.balanceOf(_alice), 0);
        assertGt(lExpectedTokenAReceived, 0);
        assertEq(_tokenA.balanceOf(_alice), lExpectedTokenAReceived);
        assertEq(_tokenB.balanceOf(_alice), lExpectedTokenBReceived);
    }

    function testBurn_Zero() public {
        // act
        vm.expectEmit(true, true, true, true);
        emit Burn(address(this), 0, 0);
        _stablePair.burn(address(this));

        // assert
        assertEq(_tokenA.balanceOf(address(this)), 0);
        assertEq(_tokenB.balanceOf(address(this)), 0);
        assertEq(_tokenA.balanceOf(address(_stablePair)), INITIAL_MINT_AMOUNT);
        assertEq(_tokenB.balanceOf(address(_stablePair)), INITIAL_MINT_AMOUNT);
    }

    function testBurn_DiffDecimalPlaces(uint aAmtToBurn) public {
        // assume
        uint lAmtToBurn = bound(aAmtToBurn, 2, 2e12 - 1);

        // arrange - tokenD has 6 decimal places, simulating USDC / USDT
        StablePair lPair = StablePair(_createPair(address(_tokenC), address(_tokenD), 1));

        _tokenC.mint(address(lPair), INITIAL_MINT_AMOUNT);
        _tokenD.mint(address(lPair), INITIAL_MINT_AMOUNT / 1e12);

        lPair.mint(address(this));

        // sanity
        assertEq(lPair.balanceOf(address(this)), 2 * INITIAL_MINT_AMOUNT - lPair.MINIMUM_LIQUIDITY());

        // act
        lPair.transfer(address(lPair), lAmtToBurn);
        (uint lAmt0, uint lAmt1) = lPair.burn(address(this));

        // assert
        (uint lAmtC, uint lAmtD) = lPair.token0() == address(_tokenC) ? (lAmt0, lAmt1) : (lAmt1, lAmt0);
        assertEq(lAmtD, 0);
        assertGt(lAmtC, 0);
    }

    function testRampA() public {
        // arrange
        uint64 lCurrentTimestamp = uint64(block.timestamp);
        uint64 lFutureATimestamp = lCurrentTimestamp + 3 days;
        uint64 lFutureAToSet = 5000;

        // act
        vm.expectEmit(true, true, true, true);
        emit RampA(
            uint64(DEFAULT_AMP_COEFF) * uint64(StableMath.A_PRECISION),
            lFutureAToSet * uint64(StableMath.A_PRECISION),
            lCurrentTimestamp,
            lFutureATimestamp
            );
        _factory.rawCall(
            address(_stablePair), abi.encodeWithSignature("rampA(uint64,uint64)", lFutureAToSet, lFutureATimestamp), 0
        );

        // assert
        (uint64 lInitialA, uint64 lFutureA, uint64 lInitialATime, uint64 lFutureATime) = _stablePair.ampData();
        assertEq(lInitialA, DEFAULT_AMP_COEFF * uint64(StableMath.A_PRECISION));
        assertEq(_stablePair.getCurrentA(), DEFAULT_AMP_COEFF);
        assertEq(lFutureA, lFutureAToSet * uint64(StableMath.A_PRECISION));
        assertEq(lInitialATime, block.timestamp);
        assertEq(lFutureATime, lFutureATimestamp);
    }

    function testRampA_OnlyFactory() public {
        // act && assert
        vm.expectRevert("P: FORBIDDEN");
        _stablePair.rampA(100, uint64(block.timestamp + 10 days));
    }

    function testRampA_SetAtMinimum() public {
        // arrange
        uint64 lCurrentTimestamp = uint64(block.timestamp);
        uint64 lFutureATimestamp = lCurrentTimestamp + 500 days;
        uint64 lFutureAToSet = uint64(StableMath.MIN_A);

        // act
        _factory.rawCall(
            address(_stablePair), abi.encodeWithSignature("rampA(uint64,uint64)", lFutureAToSet, lFutureATimestamp), 0
        );

        // assert
        (, uint64 lFutureA,,) = _stablePair.ampData();
        assertEq(lFutureA / StableMath.A_PRECISION, lFutureAToSet);
    }

    function testRampA_SetAtMaximum() public {
        // arrange
        uint64 lCurrentTimestamp = uint64(block.timestamp);
        uint64 lFutureATimestamp = lCurrentTimestamp + 5 days;
        uint64 lFutureAToSet = uint64(StableMath.MAX_A);

        // act
        _factory.rawCall(
            address(_stablePair), abi.encodeWithSignature("rampA(uint64,uint64)", lFutureAToSet, lFutureATimestamp), 0
        );

        // assert
        (, uint64 lFutureA,,) = _stablePair.ampData();
        assertEq(lFutureA / StableMath.A_PRECISION, lFutureAToSet);
    }

    function testRampA_BreachMinimum() public {
        // arrange
        uint64 lCurrentTimestamp = uint64(block.timestamp);
        uint64 lFutureATimestamp = lCurrentTimestamp + 3 days;
        uint64 lFutureAToSet = uint64(StableMath.MIN_A) - 1;

        // act & assert
        vm.expectRevert("SP: INVALID_A");
        _factory.rawCall(
            address(_stablePair), abi.encodeWithSignature("rampA(uint64,uint64)", lFutureAToSet, lFutureATimestamp), 0
        );
    }

    function testRampA_BreachMaximum() public {
        // arrange
        uint64 lCurrentTimestamp = uint64(block.timestamp);
        uint64 lFutureATimestamp = lCurrentTimestamp + 501 days;
        uint64 lFutureAToSet = uint64(StableMath.MAX_A) + 1;

        // act & assert
        vm.expectRevert("SP: INVALID_A");
        _factory.rawCall(
            address(_stablePair), abi.encodeWithSignature("rampA(uint64,uint64)", lFutureAToSet, lFutureATimestamp), 0
        );
    }

    function testRampA_MaxSpeed() public {
        // arrange
        uint64 lCurrentTimestamp = uint64(block.timestamp);
        uint64 lFutureATimestamp = lCurrentTimestamp + 1 days;
        uint64 lFutureAToSet = _stablePair.getCurrentA() * 2;

        // act
        _factory.rawCall(
            address(_stablePair), abi.encodeWithSignature("rampA(uint64,uint64)", lFutureAToSet, lFutureATimestamp), 0
        );

        // assert
        (, uint64 lFutureA,,) = _stablePair.ampData();
        assertEq(lFutureA, lFutureAToSet * StableMath.A_PRECISION);
    }

    function testRampA_BreachMaxSpeed() public {
        // arrange
        uint64 lCurrentTimestamp = uint64(block.timestamp);
        uint64 lFutureATimestamp = lCurrentTimestamp + 2 days - 1;
        uint64 lFutureAToSet = _stablePair.getCurrentA() * 4;

        // act & assert
        vm.expectRevert("SP: AMP_RATE_TOO_HIGH");
        _factory.rawCall(
            address(_stablePair), abi.encodeWithSignature("rampA(uint64,uint64)", lFutureAToSet, lFutureATimestamp), 0
        );
    }

    function testStopRampA() public {
        // arrange
        uint64 lCurrentTimestamp = uint64(block.timestamp);
        uint64 lFutureATimestamp = lCurrentTimestamp + 3 days;
        uint64 lFutureAToSet = 5000;
        _factory.rawCall(
            address(_stablePair), abi.encodeWithSignature("rampA(uint64,uint64)", lFutureAToSet, lFutureATimestamp), 0
        );

        vm.warp(lFutureATimestamp);

        // act
        _factory.rawCall(address(_stablePair), abi.encodeWithSignature("stopRampA()"), 0);

        // assert
        (uint64 lInitialA, uint64 lFutureA, uint64 lInitialATime, uint64 lFutureATime) = _stablePair.ampData();
        assertEq(lInitialA, lFutureAToSet * uint64(StableMath.A_PRECISION));
        assertEq(lFutureA, lFutureAToSet * uint64(StableMath.A_PRECISION));
        assertEq(lInitialATime, lFutureATimestamp);
        assertEq(lFutureATime, lFutureATimestamp);
    }

    function testStopRampA_OnlyFactory() public {
        // act & assert
        vm.expectRevert("P: FORBIDDEN");
        _stablePair.stopRampA();
    }

    function testStopRampA_Early(uint aFutureA) public {
        // assume
        uint64 lFutureAToSet = uint64(bound(aFutureA, StableMath.MIN_A, StableMath.MAX_A));

        // arrange
        uint64 lInitialA = _stablePair.getCurrentA();
        uint64 lCurrentTimestamp = uint64(block.timestamp);
        uint64 lFutureATimestamp = lCurrentTimestamp + 1000 days;
        _factory.rawCall(
            address(_stablePair), abi.encodeWithSignature("rampA(uint64,uint64)", lFutureAToSet, lFutureATimestamp), 0
        );

        _stepTime(lFutureATimestamp / 2);

        // act
        _factory.rawCall(address(_stablePair), abi.encodeWithSignature("stopRampA()"), 0);

        // assert
        uint lTotalADiff = lFutureAToSet > lInitialA ? lFutureAToSet - lInitialA : lInitialA - lFutureAToSet;
        uint lActualADiff =
            lFutureAToSet > lInitialA ? _stablePair.getCurrentA() - lInitialA : lInitialA - _stablePair.getCurrentA();
        assertApproxEqAbs(lActualADiff, lTotalADiff / 2, 1);
        (uint64 lNewInitialA, uint64 lNewFutureA, uint64 lInitialATime, uint64 lFutureATime) = _stablePair.ampData();
        assertEq(lNewInitialA, lNewFutureA);
        assertEq(lInitialATime, block.timestamp);
        assertEq(lFutureATime, block.timestamp);
    }

    function testStopRampA_Late(uint aFutureA) public {
        // assume
        uint64 lFutureAToSet = uint64(bound(aFutureA, StableMath.MIN_A, StableMath.MAX_A));

        // arrange
        uint64 lCurrentTimestamp = uint64(block.timestamp);
        uint64 lFutureATimestamp = lCurrentTimestamp + 1000 days;
        _factory.rawCall(
            address(_stablePair), abi.encodeWithSignature("rampA(uint64,uint64)", lFutureAToSet, lFutureATimestamp), 0
        );

        _stepTime(lFutureATimestamp + 10 days);

        // act
        _factory.rawCall(address(_stablePair), abi.encodeWithSignature("stopRampA()"), 0);

        // assert
        assertEq(_stablePair.getCurrentA(), lFutureAToSet);
        (uint64 lNewInitialA, uint64 lNewFutureA, uint64 lInitialATime, uint64 lFutureATime) = _stablePair.ampData();
        assertEq(_stablePair.getCurrentA(), lNewInitialA / StableMath.A_PRECISION);
        assertEq(lNewInitialA, lNewFutureA);
        assertEq(lInitialATime, block.timestamp);
        assertEq(lFutureATime, block.timestamp);
    }

    function testGetCurrentA() public {
        // arrange
        uint64 lCurrentTimestamp = uint64(block.timestamp);
        uint64 lFutureATimestamp = lCurrentTimestamp + 3 days;
        uint64 lFutureAToSet = 5000;

        // act
        _factory.rawCall(
            address(_stablePair), abi.encodeWithSignature("rampA(uint64,uint64)", lFutureAToSet, lFutureATimestamp), 0
        );

        // assert
        assertEq(_stablePair.getCurrentA(), DEFAULT_AMP_COEFF);

        // warp to the midpoint between the initialATime and futureATime
        vm.warp((lFutureATimestamp + block.timestamp) / 2);
        assertEq(_stablePair.getCurrentA(), (DEFAULT_AMP_COEFF + lFutureAToSet) / 2);

        // warp to the end
        vm.warp(lFutureATimestamp);
        assertEq(_stablePair.getCurrentA(), lFutureAToSet);
    }

    function testRampA_SwappingDuringRampingUp(uint aSeed, uint64 aFutureA, uint64 aDuration, uint128 aSwapAmount)
        public
    {
        // arrange
        uint64 lFutureAToSet = uint64(bound(aFutureA, _stablePair.getCurrentA(), StableMath.MAX_A));
        uint lMinRampDuration = lFutureAToSet / _stablePair.getCurrentA() * 1 days;
        uint lMaxRampDuration = 30 days; // 1 month
        uint64 lCurrentTimestamp = uint64(block.timestamp);
        uint64 lFutureATimestamp = lCurrentTimestamp + uint64(bound(aDuration, lMinRampDuration, lMaxRampDuration));
        uint lAmountToSwap = aSwapAmount / 2;

        // act
        _factory.rawCall(
            address(_stablePair), abi.encodeWithSignature("rampA(uint64,uint64)", lFutureAToSet, lFutureATimestamp), 0
        );

        uint lAmountOutBeforeRamp = _stablePair.getAmountOut(address(_tokenA), lAmountToSwap);
        uint64 lRemainingTime = lFutureATimestamp - lCurrentTimestamp;

        uint64 lCheck1 = uint64(bound(aSeed, 0, lRemainingTime));
        skip(lCheck1);
        uint lAmountOutT1 = _stablePair.getAmountOut(address(_tokenA), lAmountToSwap);

        lRemainingTime -= lCheck1;
        uint64 lCheck2 = uint64(bound(uint(keccak256(abi.encode(lCheck1))), 0, lRemainingTime));
        skip(lCheck2);
        uint lAmountOutT2 = _stablePair.getAmountOut(address(_tokenA), lAmountToSwap);

        lRemainingTime -= lCheck2;
        uint64 lCheck3 = uint64(bound(uint(keccak256(abi.encode(lCheck2))), 0, lRemainingTime));
        skip(lCheck3);
        uint lAmountOutT3 = _stablePair.getAmountOut(address(_tokenA), lAmountToSwap);

        lRemainingTime -= lCheck3;
        skip(lRemainingTime);
        uint lAmountOutT4 = _stablePair.getAmountOut(address(_tokenA), lAmountToSwap);

        // assert - output amount over time should be increasing or be within 1 due to rounding error
        assertTrue(lAmountOutT1 >= lAmountOutBeforeRamp || MathUtils.within1(lAmountOutT1, lAmountOutBeforeRamp));
        assertTrue(lAmountOutT2 >= lAmountOutT1 || MathUtils.within1(lAmountOutT2, lAmountOutT1));
        assertTrue(lAmountOutT3 >= lAmountOutT2 || MathUtils.within1(lAmountOutT3, lAmountOutT2));
        assertTrue(lAmountOutT4 >= lAmountOutT3 || MathUtils.within1(lAmountOutT4, lAmountOutT3));
    }

    function testRampA_SwappingDuringRampingDown(uint aSeed, uint64 aFutureA, uint64 aDuration, uint128 aSwapAmount)
        public
    {
        // arrange
        uint64 lFutureAToSet = uint64(bound(aFutureA, StableMath.MIN_A, _stablePair.getCurrentA()));
        uint lMinRampDuration = _stablePair.getCurrentA() / lFutureAToSet * 1 days;
        uint lMaxRampDuration = 1000 days;
        uint64 lCurrentTimestamp = uint64(block.timestamp);
        uint64 lFutureATimestamp = lCurrentTimestamp + uint64(bound(aDuration, lMinRampDuration, lMaxRampDuration));
        uint lAmountToSwap = aSwapAmount / 2;

        // act
        _factory.rawCall(
            address(_stablePair), abi.encodeWithSignature("rampA(uint64,uint64)", lFutureAToSet, lFutureATimestamp), 0
        );

        uint lAmountOutBeforeRamp = _stablePair.getAmountOut(address(_tokenA), lAmountToSwap);
        uint64 lRemainingTime = lFutureATimestamp - lCurrentTimestamp;

        uint64 lCheck1 = uint64(bound(aSeed, 0, lRemainingTime));
        skip(lCheck1);
        uint lAmountOutT1 = _stablePair.getAmountOut(address(_tokenA), lAmountToSwap);

        lRemainingTime -= lCheck1;
        uint64 lCheck2 = uint64(bound(uint(keccak256(abi.encode(lCheck1))), 0, lRemainingTime));
        skip(lCheck2);
        uint lAmountOutT2 = _stablePair.getAmountOut(address(_tokenA), lAmountToSwap);

        lRemainingTime -= lCheck2;
        uint64 lCheck3 = uint64(bound(uint(keccak256(abi.encode(lCheck1))), 0, lRemainingTime));
        skip(lCheck3);
        uint lAmountOutT3 = _stablePair.getAmountOut(address(_tokenA), lAmountToSwap);

        lRemainingTime -= lCheck3;
        skip(lRemainingTime);
        uint lAmountOutT4 = _stablePair.getAmountOut(address(_tokenA), lAmountToSwap);

        // assert - output amount over time should be decreasing or within 1 due to rounding error
        assertTrue(lAmountOutT1 <= lAmountOutBeforeRamp || MathUtils.within1(lAmountOutT1, lAmountOutBeforeRamp));
        assertTrue(lAmountOutT2 <= lAmountOutT1 || MathUtils.within1(lAmountOutT2, lAmountOutT1));
        assertTrue(lAmountOutT3 <= lAmountOutT2 || MathUtils.within1(lAmountOutT3, lAmountOutT2));
        assertTrue(lAmountOutT4 <= lAmountOutT3 || MathUtils.within1(lAmountOutT4, lAmountOutT3));
    }

    // inspired from saddle's test case, which is testing for this vulnerability
    // https://medium.com/@peter_4205/curve-vulnerability-report-a1d7630140ec
    function testAttackWhileRampingDown_ShortInterval() public {
        // arrange
        uint64 lNewA = 400;
        vm.startPrank(address(_factory));
        _stablePair.rampA(lNewA, uint64(block.timestamp + 4 days));
        _stablePair.setCustomSwapFee(100); // 1 bp
        vm.stopPrank();

        // swap 70e18 of tokenA to tokenB to cause a large imbalance
        uint lSwapAmt = 70e18;
        _tokenA.mint(address(_stablePair), lSwapAmt);
        uint lAmtOut = _stablePair.swap(int(lSwapAmt), true, address(this), bytes(""));

        assertEq(lAmtOut, 69_897_580_651_885_320_277);
        assertEq(_tokenB.balanceOf(address(this)), 69_897_580_651_885_320_277);

        // Pool is imbalanced! Now trades from tokenB -> tokenA may be profitable in small sizes
        // tokenA balance in the pool  : 170e18
        // tokenB balance in the pool : 30.10e18
        (uint112 lReserve0, uint112 lReserve1,) = _stablePair.getReserves();
        assertEq(lReserve0, 170e18);
        assertEq(lReserve1, 30_102_419_348_114_679_723);

        _stepTime(20 minutes);
        assertEq(_stablePair.getCurrentA(), 997);

        // act - now attacker swaps from tokenB to tokenA
        _tokenB.transfer(address(_stablePair), 69_897_580_651_885_320_277);
        _stablePair.swap(-69_897_580_651_885_320_277, true, address(this), bytes(""));

        // assert
        // the attacker did not get more than what he started with
        assertLt(_tokenA.balanceOf(address(this)), lSwapAmt);
        // the pool was not worse off
        (lReserve0, lReserve1,) = _stablePair.getReserves();
        assertGt(lReserve0, INITIAL_MINT_AMOUNT);
        assertEq(lReserve1, INITIAL_MINT_AMOUNT);
    }

    // this is to simulate a sudden large A change, without trades having taken place in between
    // this will not happen in our case as A is changed gently over a period not suddenly
    function testAttackWhileRampingDown_LongInterval() public {
        // arrange
        uint64 lNewA = 400;
        vm.startPrank(address(_factory));
        _stablePair.rampA(lNewA, uint64(block.timestamp + 4 days));
        _stablePair.setCustomSwapFee(100); // 1 bp
        vm.stopPrank();

        // swap 70e18 of tokenA to tokenB to cause a large imbalance
        uint lSwapAmt = 70e18;
        _tokenA.mint(address(_stablePair), lSwapAmt);
        uint lAmtOut = _stablePair.swap(int(lSwapAmt), true, address(this), bytes(""));

        assertEq(lAmtOut, 69_897_580_651_885_320_277);
        assertEq(_tokenB.balanceOf(address(this)), 69_897_580_651_885_320_277);

        // Pool is imbalanced! Now trades from tokenB -> tokenA may be profitable in small sizes
        // tokenA balance in the pool  : 170e18
        // tokenB balance in the pool : 30.10e18
        (uint112 lReserve0, uint112 lReserve1,) = _stablePair.getReserves();
        assertEq(lReserve0, 170e18);
        assertEq(lReserve1, 30_102_419_348_114_679_723);

        // to simulate that no trades have taken place throughout the process of ramping down
        // or rapid A change
        _stepTime(4 days);
        assertEq(_stablePair.getCurrentA(), 400);

        // act - now attacker swaps from tokenB to tokenA
        _tokenB.transfer(address(_stablePair), 69_897_580_651_885_320_277);
        _stablePair.swap(-69_897_580_651_885_320_277, true, address(this), bytes(""));

        // assert - the attack was successful
        // the attacker got more than what he started with
        assertGt(_tokenA.balanceOf(address(this)), lSwapAmt);
        // the pool is worse off by 0.13%
        (lReserve0, lReserve1,) = _stablePair.getReserves();
        assertEq(lReserve0, 99_871_702_539_906_228_887);
        assertEq(lReserve1, INITIAL_MINT_AMOUNT);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    ORACLE
    //////////////////////////////////////////////////////////////////////////*/

    function testOracle_NoWriteInSameTimestamp() public {
        // arrange
        uint16 lInitialIndex = _stablePair.index();
        uint lAmountToSwap = 1e17;

        // act
        _tokenA.mint(address(_stablePair), lAmountToSwap);
        _stablePair.swap(int(lAmountToSwap), true, address(this), "");

        vm.prank(_alice);
        _stablePair.transfer(address(_stablePair), 1e18);
        _stablePair.burn(address(this));

        _stablePair.sync();

        // assert
        uint16 lFinalIndex = _stablePair.index();
        assertEq(lFinalIndex, lInitialIndex);
    }

    function testOracle_WrapsAroundAfterFull() public {
        // arrange
        uint lAmountToSwap = 1e15;
        uint lMaxObservations = 2 ** 16;

        // act
        for (uint i = 0; i < lMaxObservations + 4; ++i) {
            _stepTime(5);
            _tokenA.mint(address(_stablePair), lAmountToSwap);
            _stablePair.swap(int(lAmountToSwap), true, address(this), "");
        }

        // assert
        assertEq(_stablePair.index(), 3);
    }

    function testWriteObservations() external {
        // arrange
        // swap 1
        _stepTime(1);
        (uint lReserve0, uint lReserve1,) = _stablePair.getReserves();
        _tokenA.mint(address(_stablePair), 5e18);
        _stablePair.swap(5e18, true, address(this), "");

        // swap 2
        _stepTime(1);
        (lReserve0, lReserve1,) = _stablePair.getReserves();
        _tokenA.mint(address(_stablePair), 5e18);
        _stablePair.swap(5e18, true, address(this), "");

        // sanity
        assertEq(_stablePair.index(), 1);

        Observation memory lObs = _oracleCaller.observation(_stablePair, 0);
        assertTrue(lObs.logAccRawPrice == 0);
        assertTrue(lObs.logAccClampedPrice == 0);
        assertTrue(lObs.logAccLiquidity != 0);
        assertTrue(lObs.timestamp != 0);

        lObs = _oracleCaller.observation(_stablePair, 1);
        assertTrue(lObs.logAccRawPrice != 0);
        assertTrue(lObs.logAccClampedPrice != 0);
        assertTrue(lObs.logAccLiquidity != 0);
        assertTrue(lObs.timestamp != 0);

        // act
        _writeObservation(_stablePair, 0, int112(1337), int56(-1337), int56(-1337), uint32(666));

        // assert
        lObs = _oracleCaller.observation(_stablePair, 0);
        assertEq(lObs.logAccRawPrice, int112(1337));
        assertEq(lObs.logAccClampedPrice, int112(-1337));
        assertEq(lObs.logAccLiquidity, int112(-1337));
        assertEq(lObs.timestamp, uint32(666));

        lObs = _oracleCaller.observation(_stablePair, 1);
        assertTrue(lObs.logAccRawPrice != 0);
        assertTrue(lObs.logAccClampedPrice != 0);
        assertTrue(lObs.logAccLiquidity != 0);
        assertTrue(lObs.timestamp != 0);
    }

    function testOracle_OverflowAccPrice() public {
        // arrange - make the last observation close to overflowing
        _writeObservation(
            _stablePair, _stablePair.index(), type(int112).max, type(int56).max, 0, uint32(block.timestamp)
        );
        Observation memory lPrevObs = _oracleCaller.observation(_stablePair, _stablePair.index());

        // act
        uint lAmountToSwap = 5e18;
        _tokenB.mint(address(_stablePair), lAmountToSwap);
        _stablePair.swap(-int(lAmountToSwap), true, address(this), "");

        _stepTime(5);
        _stablePair.sync();

        // assert - when it overflows it goes from a very positive number to a very negative number
        Observation memory lCurrObs = _oracleCaller.observation(_stablePair, _stablePair.index());
        assertLt(lCurrObs.logAccRawPrice, lPrevObs.logAccRawPrice);
    }

    function testOracle_OverflowAccLiquidity() public {
        // arrange
        _writeObservation(_stablePair, _stablePair.index(), 0, 0, type(int56).max, uint32(block.timestamp));
        Observation memory lPrevObs = _oracleCaller.observation(_stablePair, _stablePair.index());

        // act
        _stepTime(5);
        _stablePair.sync();

        // assert
        Observation memory lCurrObs = _oracleCaller.observation(_stablePair, _stablePair.index());
        assertLt(lCurrObs.logAccLiquidity, lPrevObs.logAccLiquidity);
    }

    function testOracle_CorrectPrice() public {
        // arrange
        uint lAmountToSwap = 1e18;
        _stepTime(5);

        // act
        _tokenA.mint(address(_stablePair), lAmountToSwap);
        _stablePair.swap(int(lAmountToSwap), true, address(this), "");

        (uint lReserve0_1, uint lReserve1_1,) = _stablePair.getReserves();
        uint lPrice1 = StableOracleMath.calcSpotPrice(_stablePair.getCurrentAPrecise(), lReserve0_1, lReserve1_1);
        _stepTime(5);

        _tokenA.mint(address(_stablePair), lAmountToSwap);
        _stablePair.swap(int(lAmountToSwap), true, address(this), "");
        (uint lReserve0_2, uint lReserve1_2,) = _stablePair.getReserves();
        uint lPrice2 = StableOracleMath.calcSpotPrice(_stablePair.getCurrentAPrecise(), lReserve0_2, lReserve1_2);

        _stepTime(5);
        _stablePair.sync();

        // assert
        Observation memory lObs0 = _oracleCaller.observation(_stablePair, 0);
        Observation memory lObs1 = _oracleCaller.observation(_stablePair, 1);
        Observation memory lObs2 = _oracleCaller.observation(_stablePair, 2);

        assertApproxEqRel(
            LogCompression.fromLowResLog(
                (lObs1.logAccRawPrice - lObs0.logAccRawPrice) / int32(lObs1.timestamp - lObs0.timestamp)
            ),
            lPrice1,
            0.0001e18
        );
        assertApproxEqRel(
            LogCompression.fromLowResLog(
                (lObs2.logAccRawPrice - lObs0.logAccRawPrice) / int32(lObs2.timestamp - lObs0.timestamp)
            ),
            Math.sqrt(lPrice1 * lPrice2),
            0.0001e18
        );
    }

    function testOracle_SimplePrices() external {
        // prices = [1, 0.4944, 0.0000936563]
        // geo_mean = sqrt3(1 * 0.4944 * 0000936563) = 0.0166676

        // arrange
        vm.prank(address(_factory));
        _stablePair.setCustomSwapFee(0);

        // price = 1
        _stepTime(10);

        // act
        // price = 0.4944
        _tokenA.mint(address(_stablePair), 100e18);
        _stablePair.swap(100e18, true, _bob, "");
        (uint lReserve0_1, uint lReserve1_1,) = _stablePair.getReserves();
        uint lSpotPrice1 = StableOracleMath.calcSpotPrice(_stablePair.getCurrentAPrecise(), lReserve0_1, lReserve1_1);
        _stepTime(10);

        // price = 0.0000936563
        _tokenA.mint(address(_stablePair), 200e18);
        _stablePair.swap(200e18, true, _bob, "");
        (uint lReserve0_2, uint lReserve1_2,) = _stablePair.getReserves();
        uint lSpotPrice2 = StableOracleMath.calcSpotPrice(_stablePair.getCurrentAPrecise(), lReserve0_2, lReserve1_2);
        _stepTime(10);
        _stablePair.sync();

        // assert
        Observation memory lObs0 = _oracleCaller.observation(_stablePair, 0);
        Observation memory lObs1 = _oracleCaller.observation(_stablePair, 1);
        Observation memory lObs2 = _oracleCaller.observation(_stablePair, 2);

        assertEq(lObs0.logAccRawPrice, LogCompression.toLowResLog(1e18) * 10, "1");
        assertEq(
            lObs1.logAccRawPrice,
            LogCompression.toLowResLog(1e18) * 10 + LogCompression.toLowResLog(lSpotPrice1) * 10,
            "2"
        );
        assertEq(
            lObs2.logAccRawPrice,
            LogCompression.toLowResLog(1e18) * 10 + LogCompression.toLowResLog(lSpotPrice1) * 10
                + LogCompression.toLowResLog(lSpotPrice2) * 10,
            "3"
        );

        // Price for observation window 1-2
        assertApproxEqRel(
            LogCompression.fromLowResLog(
                (lObs1.logAccRawPrice - lObs0.logAccRawPrice) / int32(lObs1.timestamp - lObs0.timestamp)
            ),
            lSpotPrice1,
            0.0001e18
        );
        // Price for observation window 2-3
        assertApproxEqRel(
            LogCompression.fromLowResLog(
                (lObs2.logAccRawPrice - lObs1.logAccRawPrice) / int32(lObs2.timestamp - lObs1.timestamp)
            ),
            lSpotPrice2,
            0.0001e18
        );
        // Price for observation window 1-3
        assertApproxEqRel(
            LogCompression.fromLowResLog(
                (lObs2.logAccRawPrice - lObs0.logAccRawPrice) / int32(lObs2.timestamp - lObs0.timestamp)
            ),
            Math.sqrt(lSpotPrice1 * lSpotPrice2),
            0.0001e18
        );
    }

    function testOracle_CorrectLiquidity() public {
        // arrange
        uint lAmountToBurn = 1e18;

        // act
        _stepTime(5);
        vm.prank(_alice);
        _stablePair.transfer(address(_stablePair), lAmountToBurn);
        _stablePair.burn(address(this));

        // assert
        Observation memory lObs0 = _oracleCaller.observation(_stablePair, _stablePair.index());
        uint lAverageLiq = LogCompression.fromLowResLog(lObs0.logAccLiquidity / 5);
        // we check that it is within 0.01% of accuracy
        // sqrt(INITIAL_MINT_AMOUNT * INITIAL_MINT_AMOUNT) == INITIAL_MINT_AMOUNT
        assertApproxEqRel(lAverageLiq, INITIAL_MINT_AMOUNT, 0.0001e18);

        // act
        _stepTime(5);
        _stablePair.sync();

        // assert
        Observation memory lObs1 = _oracleCaller.observation(_stablePair, _stablePair.index());
        uint lAverageLiq2 = LogCompression.fromLowResLog((lObs1.logAccLiquidity - lObs0.logAccLiquidity) / 5);
        assertApproxEqRel(lAverageLiq2, INITIAL_MINT_AMOUNT - lAmountToBurn / 2, 0.0001e18);
    }

    function testOracle_LiquidityAtMaximum() external {
        // arrange
        uint lLiquidityToAdd = type(uint112).max - INITIAL_MINT_AMOUNT;
        _stepTime(5);
        _tokenA.mint(address(_stablePair), lLiquidityToAdd);
        _tokenB.mint(address(_stablePair), lLiquidityToAdd);
        _stablePair.mint(address(this));

        // sanity
        (uint112 lReserve0, uint112 lReserve1,) = _stablePair.getReserves();
        assertEq(lReserve0, type(uint112).max);
        assertEq(lReserve1, type(uint112).max);

        // act
        _stepTime(5);
        _stablePair.sync();

        // assert
        uint lTotalSupply = _stablePair.totalSupply();
        assertEq(lTotalSupply, uint(type(uint112).max) * 2);

        Observation memory lObs0 = _oracleCaller.observation(_stablePair, 0);
        Observation memory lObs1 = _oracleCaller.observation(_stablePair, _stablePair.index());
        assertApproxEqRel(
            type(uint112).max,
            LogCompression.fromLowResLog((lObs1.logAccLiquidity - lObs0.logAccLiquidity) / 5),
            0.0001e18
        );
    }

    function testOracle_ClampedPrice_NoDiffWithinLimit() external {
        // arrange
        _stepTime(5);
        uint lSwapAmt = 57e18;
        _tokenB.mint(address(_stablePair), lSwapAmt);
        _stablePair.swap(-int(lSwapAmt), true, address(this), bytes(""));

        // sanity
        assertEq(_stablePair.prevClampedPrice(), 1e18);

        // act
        _stepTime(5);
        _stablePair.sync();

        // assert
        Observation memory lObs1 = _oracleCaller.observation(_stablePair, 1);
        // no diff between raw and clamped prices
        assertEq(lObs1.logAccClampedPrice, lObs1.logAccRawPrice);
        assertLt(_stablePair.prevClampedPrice(), 1.0025e18);
    }
}
