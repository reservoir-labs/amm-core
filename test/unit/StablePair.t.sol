pragma solidity 0.8.13;

import "test/__fixtures/BaseTest.sol";
import "test/__fixtures/MintableERC20.sol";

import { Math } from "src/libraries/Math.sol";
import { MathUtils } from "src/libraries/MathUtils.sol";
import { LogCompression } from "src/libraries/LogCompression.sol";
import { StableOracleMath } from "src/libraries/StableOracleMath.sol";
import { StableMath } from "src/libraries/StableMath.sol";
import { StablePair, AmplificationData } from "src/curve/stable/StablePair.sol";
import { GenericFactory } from "src/GenericFactory.sol";

contract StablePairTest is BaseTest
{
    event RampA(uint64 initialA, uint64 futureA, uint64 initialTime, uint64 futureTime);

    function _calculateConstantProductOutput(
        uint256 aReserveIn,
        uint256 aReserveOut,
        uint256 aTokenIn,
        uint256 aFee
    ) private view returns (uint256 rExpectedOut)
    {
        uint256 MAX_FEE = _constantProductPair.FEE_ACCURACY();
        uint256 lAmountInWithFee = aTokenIn * (MAX_FEE - aFee);
        uint256 lNumerator = lAmountInWithFee * aReserveOut;
        uint256 lDenominator = aReserveIn * MAX_FEE + lAmountInWithFee;

        rExpectedOut = lNumerator / lDenominator;
    }

    function testFactoryAmpTooLow() public
    {
        // arrange
        _factory.set(keccak256("ConstantProductPair::amplificationCoefficient"), bytes32(uint256(StableMath.MIN_A - 1)));

        // act & assert
        vm.expectRevert("FACTORY: DEPLOY_FAILED");
        _createPair(address(_tokenC), address(_tokenD), 1);
    }

    function testFactoryAmpTooHigh() public
    {
        // arrange
        _factory.set(keccak256("ConstantProductPair::amplificationCoefficient"), bytes32(uint256(StableMath.MAX_A + 1)));

        // act & assert
        vm.expectRevert("FACTORY: DEPLOY_FAILED");
        _createPair(address(_tokenC), address(_tokenD), 1);
    }

    function testMint() public
    {
        // arrange
        uint256 lLpTokenTotalSupply = _stablePair.totalSupply();
        (uint256 lReserve0, uint256 lReserve1, ) = _stablePair.getReserves();
        uint256 lOldLiquidity = lReserve0 + lReserve1;
        uint256 lLiquidityToAdd = 5e18;

        // act
        _tokenA.mint(address(_stablePair), lLiquidityToAdd);
        _tokenB.mint(address(_stablePair), lLiquidityToAdd);
        _stablePair.mint(address(this));

        // assert
        // this works only because the pools are balanced. When the pool is imbalanced the calculation will differ
        uint256 lAdditionalLpTokens = ((INITIAL_MINT_AMOUNT + lLiquidityToAdd) * 2 - lOldLiquidity) * lLpTokenTotalSupply / lOldLiquidity;
        assertEq(_stablePair.balanceOf(address(this)), lAdditionalLpTokens);
    }

    function testMint_OnlyTransferOneToken() public
    {
        // arrange
        StablePair lPair = StablePair(_createPair(address(_tokenA), address(_tokenC), 1));
        _tokenA.mint(address(lPair), 5e18);

        // act & assert
        vm.expectRevert(stdError.divisionError);
        lPair.mint(address(this));
    }

    function testMint_NonOptimalProportion() public
    {
        // arrange
        uint256 lAmountAToMint = 1e18;
        uint256 lAmountBToMint = 100e18;

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
    function testMint_NonOptimalProportion_ThenBurn() public
    {
        // arrange
        uint256 lBefore = vm.snapshot();
        uint256 lAmountAToMint = 1e18;
        uint256 lAmountBToMint = 100e18;

        _tokenA.mint(address(_stablePair), lAmountAToMint);
        _tokenB.mint(address(_stablePair), lAmountBToMint);

        // act
        _stablePair.mint(address(this));
        _stablePair.transfer(address(_stablePair), _stablePair.balanceOf(address(this)));
        _stablePair.burn(address(this));

        uint256 lBurnOutputA = _tokenA.balanceOf(address(this));
        uint256 lBurnOutputB = _tokenB.balanceOf(address(this));

        vm.revertTo(lBefore);

        // swap
        uint256 lAmountToSwap = lAmountBToMint - lBurnOutputB;
        _tokenB.mint(address(_stablePair), lAmountToSwap);
        _stablePair.swap(-int256(lAmountToSwap), true, address(this), bytes(""));

        uint256 lSwapOutputA = _tokenA.balanceOf(address(this));

        // assert
        assertLt(lBurnOutputA, lSwapOutputA + lAmountAToMint);
    }

    function testMintFee_CallableBySelf() public
    {
        // arrange
        vm.prank(address(_stablePair));

        // act
        (uint256 lTotalSupply, ) = _stablePair.mintFee(0, 0);

        // assert
        assertEq(lTotalSupply, _stablePair.totalSupply());
    }

    function testMintFee_NotCallableByOthers() public
    {
        // act & assert
        vm.expectRevert("SP: NOT_SELF");
        _stablePair.mintFee(0, 0);
    }

    function testMintFee_WhenRampingA_PoolBalanced(uint256 aFutureA) public
    {
        // assume - for ramping up or down from 1000
        uint64 lFutureAToSet = uint64(bound(aFutureA, 500, 5000));
        vm.assume(lFutureAToSet != 1000);

        // arrange
        StablePair lOtherPair = StablePair(_createPair(address(_tokenA), address(_tokenC), 1));
        _tokenA.mint(address(lOtherPair), INITIAL_MINT_AMOUNT);
        _tokenC.mint(address(lOtherPair), INITIAL_MINT_AMOUNT);
        lOtherPair.mint(_alice);

        for (uint256 i = 0; i < 10; ++i) {
            uint256 lAmountToSwap = 5e18;

            _tokenA.mint(address(_stablePair), lAmountToSwap);
            _stablePair.swap(int256(lAmountToSwap), true, address(this), bytes(""));

            _tokenB.mint(address(_stablePair), lAmountToSwap);
            _stablePair.swap(-int256(lAmountToSwap), true, address(this), bytes(""));

            _tokenA.mint(address(lOtherPair), lAmountToSwap);
            lOtherPair.swap(int256(lAmountToSwap), true, address(this), bytes(""));

            _tokenC.mint(address(lOtherPair), lAmountToSwap);
            lOtherPair.swap(-int256(lAmountToSwap), true, address(this), bytes(""));
        }

        // we change A for _stablePair but not for lOtherPair
        uint64 lCurrentTimestamp = uint64(block.timestamp);
        uint64 lFutureATimestamp = lCurrentTimestamp + 3 days;

        _factory.rawCall(
            address(_stablePair),
            abi.encodeWithSignature("rampA(uint64,uint64)", lFutureAToSet, lFutureATimestamp),
            0
        );

        // sanity
        assertEq(_stablePair.getCurrentA(), lOtherPair.getCurrentA());

        // act - warp to the end
        vm.warp(lFutureATimestamp);
        assertEq(_stablePair.getCurrentA(), lFutureAToSet);
        assertTrue(_stablePair.getCurrentA() != lOtherPair.getCurrentA());

        // sanity
        (uint256 lReserve0_S, uint256 lReserve1_S, ) = _stablePair.getReserves();
        (uint256 lReserve0_O, uint256 lReserve1_O, ) = lOtherPair.getReserves();
        assertEq(lReserve0_S, lReserve0_O);
        assertEq(lReserve1_S, lReserve1_O);

        vm.prank(address(_stablePair));
        (uint256 lTotalSupply1, ) = _stablePair.mintFee(lReserve0_S, lReserve1_S);
        vm.prank(address(lOtherPair));
        (uint256 lTotalSupply2, ) = lOtherPair.mintFee(lReserve0_O, lReserve1_O);

        // assert - even after the difference in A, we expect the platformFee received (LP tokens) to be the same
        assertEq(_stablePair.balanceOf(address(_platformFeeTo)), lOtherPair.balanceOf(address(_platformFeeTo)));
        assertEq(lTotalSupply1, lTotalSupply2);
    }

    function testMintFee_WhenRampingA_PoolUnbalanced(uint256 aFutureA) public
    {
        // assume - for ramping up or down from 1000
        uint64 lFutureAToSet = uint64(bound(aFutureA, 500, 5000));
        vm.assume(lFutureAToSet != 1000);

        // arrange
        StablePair lOtherPair = StablePair(_createPair(address(_tokenA), address(_tokenC), 1));
        _tokenA.mint(address(lOtherPair), INITIAL_MINT_AMOUNT);
        _tokenC.mint(address(lOtherPair), INITIAL_MINT_AMOUNT);
        lOtherPair.mint(_alice);

        for (uint256 i = 0; i < 10; ++i) {
            uint256 lAmountToSwap = 5e18;

            _tokenA.mint(address(_stablePair), lAmountToSwap);
            _stablePair.swap(int256(lAmountToSwap), true, address(this), bytes(""));

            _tokenA.mint(address(lOtherPair), lAmountToSwap);
            lOtherPair.swap(int256(lAmountToSwap), true, address(this), bytes(""));
        }

        // we change A for _stablePair but not for lOtherPair
        uint64 lCurrentTimestamp = uint64(block.timestamp);
        uint64 lFutureATimestamp = lCurrentTimestamp + 3 days;

        _factory.rawCall(
            address(_stablePair),
            abi.encodeWithSignature("rampA(uint64,uint64)", lFutureAToSet, lFutureATimestamp),
            0
        );

        // sanity
        assertEq(_stablePair.getCurrentA(), lOtherPair.getCurrentA());

        // act - warp to the end
        vm.warp(lFutureATimestamp);
        assertEq(_stablePair.getCurrentA(), lFutureAToSet);
        assertTrue(_stablePair.getCurrentA() != lOtherPair.getCurrentA());

        // sanity
        (uint256 lReserve0_S, uint256 lReserve1_S, ) = _stablePair.getReserves();
        (uint256 lReserve0_O, uint256 lReserve1_O, ) = lOtherPair.getReserves();
        assertEq(lReserve0_S, lReserve0_O);
        assertEq(lReserve1_S, lReserve1_O);

        vm.prank(address(_stablePair));
        (uint256 lTotalSupply1, ) = _stablePair.mintFee(lReserve0_S, lReserve1_S);
        vm.prank(address(lOtherPair));
        (uint256 lTotalSupply2, ) = lOtherPair.mintFee(lReserve0_O, lReserve1_O);

        // assert - even after the difference in A, we expect the platformFee received (LP tokens) to be the same
        assertEq(_stablePair.balanceOf(address(_platformFeeTo)), lOtherPair.balanceOf(address(_platformFeeTo)));
        assertEq(lTotalSupply1, lTotalSupply2);
    }

    function testMintFee_DiffPlatformFees(uint256 aPlatformFee) public
    {
        // assume
        uint256 lPlatformFee = bound(aPlatformFee, 0, _stablePair.MAX_PLATFORM_FEE());

        // arrange
        StablePair lPair = StablePair(_createPair(address(_tokenC), address(_tokenD), 1));
        vm.prank(address(_factory));
        lPair.setCustomPlatformFee(lPlatformFee);
        _tokenC.mint(address(lPair), 100_000_000e18);
        _tokenD.mint(address(lPair), 120_000_000e6);
        lPair.mint(address(this));
        uint256 lOldLiq = StableMath._computeLiquidityFromAdjustedBalances(
            120_000_000e6 * 1e12, 100_000_000e18, 2 * lPair.getCurrentAPrecise()
        );

        uint256 lCSwapAmt = 11_301_493e18;
        uint256 lDSwapAmt = 10_402_183e6;

        // sanity
        assertEq(lPair.platformFee(), lPlatformFee);

        // increase liq by swapping back and forth
        for (uint i; i < 20; ++i) {
            _tokenD.mint(address(lPair), lDSwapAmt);
            lPair.swap(int256(lDSwapAmt), true, address(this), bytes(""));

            _tokenC.mint(address(lPair), lCSwapAmt);
            lPair.swap(-int256(lCSwapAmt), true, address(this), bytes(""));
        }

        (uint256 lReserve0, uint256 lReserve1, ) = lPair.getReserves();
        uint256 lTotalSupply = lPair.totalSupply();

        // act
        lPair.transfer(address(lPair), 1e18);
        lPair.burn(address(this));

        // assert
        uint256 lNewLiq = StableMath._computeLiquidityFromAdjustedBalances(
            lReserve0 * 1e12,
            lReserve1,
            2 * lPair.getCurrentAPrecise()
        );
        uint256 lGrowthInLiq = lNewLiq - lOldLiq;
        uint256 lExpectedPlatformFee =
            lTotalSupply * lGrowthInLiq * lPlatformFee
            / ((lPair.FEE_ACCURACY() - lPlatformFee ) * lNewLiq + lPlatformFee * lOldLiq);

        assertEq(lPair.balanceOf(_platformFeeTo), lExpectedPlatformFee);
        assertApproxEqRel(
            lExpectedPlatformFee * 1e18 / lGrowthInLiq, lPlatformFee * 1e18 / lPair.FEE_ACCURACY(), 0.006e18
        );
    }

    function testSwap() public
    {
        // act
        uint256 lAmountToSwap = 5e18;
        _tokenA.mint(address(_stablePair), lAmountToSwap);
        uint256 lAmountOut = _stablePair.swap(int256(lAmountToSwap), true, address(this), "");

        // assert
        assertEq(lAmountOut, _tokenB.balanceOf(address(this)));
    }

    function testSwap_ZeroInput() public
    {
        // act & assert
        vm.expectRevert("SP: AMOUNT_ZERO");
        _stablePair.swap(0, true, address(this), "");
    }

    function testSwap_Token0ExactOut(uint256 aAmountOut) public
    {
        // assume
        uint256 lAmountOut = bound(aAmountOut, 1e6, INITIAL_MINT_AMOUNT - 1);

        // arrange
        uint256 lSwapFee = 3_000; // 0.3%
        (uint112 lReserve0, uint112 lReserve1, ) = _stablePair.getReserves();
        uint256 lAmountIn = StableMath._getAmountIn(lAmountOut, lReserve0, lReserve1, 1, 1, true, lSwapFee, 2 * _stablePair.getCurrentAPrecise());

        // sanity - given a balanced pool, the amountIn should be greater than amountOut
        assertGt(lAmountIn, lAmountOut);

        // act
        _tokenB.mint(address(_stablePair), lAmountIn);
        uint256 lActualOut = _stablePair.swap(int256(lAmountOut), false, address(this), bytes(""));

        // assert
        uint256 inverse = StableMath._getAmountOut(lAmountIn, lReserve0, lReserve1, 1, 1, false, lSwapFee, 2 * _stablePair.getCurrentAPrecise());
        // todo: investigate why it has this (small) difference of around (less than 1/10 of a basis point)
        assertApproxEqRel(inverse, lActualOut, 0.00001e18);
        assertEq(lActualOut, lAmountOut);
    }

    function testSwap_Token1ExactOut(uint256 aAmountOut) public
    {
        // assume
        uint256 lAmountOut = bound(aAmountOut, 1e6, INITIAL_MINT_AMOUNT - 1);

        // arrange
        uint256 lSwapFee = 3_000;
        (uint112 lReserve0, uint112 lReserve1, ) = _stablePair.getReserves();
        uint256 lAmountIn = StableMath._getAmountIn(lAmountOut, lReserve0, lReserve1, 1, 1, false, lSwapFee, 2 * _stablePair.getCurrentAPrecise());

        // sanity - given a balanced pool, the amountIn should be greater than amountOut
        assertGt(lAmountIn, lAmountOut);

        // act
        _tokenA.mint(address(_stablePair), lAmountIn);
        uint256 lActualOut = _stablePair.swap(-int256(lAmountOut), false, address(this), bytes(""));

        // assert
        uint256 inverse = StableMath._getAmountOut(lAmountIn, lReserve0, lReserve1, 1, 1, true, lSwapFee, 2 * _stablePair.getCurrentAPrecise());
        // todo: investigate why it has this (small) difference of around (less than 1/10 of a basis point)
        assertApproxEqRel(inverse, lActualOut, 0.00001e18);
        assertEq(lActualOut, lAmountOut);
    }

    function testSwap_ExactOutExceedReserves() public
    {
        // act & assert
        vm.expectRevert("SP: NOT_ENOUGH_LIQ");
        _stablePair.swap(int256(INITIAL_MINT_AMOUNT), false, address(this), bytes(""));

        vm.expectRevert("SP: NOT_ENOUGH_LIQ");
        _stablePair.swap(int256(INITIAL_MINT_AMOUNT + 1), false, address(this), bytes(""));

        vm.expectRevert("SP: NOT_ENOUGH_LIQ");
        _stablePair.swap(-int256(INITIAL_MINT_AMOUNT), false, address(this), bytes(""));

        vm.expectRevert("SP: NOT_ENOUGH_LIQ");
        _stablePair.swap(-int256(INITIAL_MINT_AMOUNT + 1), false, address(this), bytes(""));
    }

    function testSwap_BetterPerformanceThanConstantProduct() public
    {
        // act
        uint256 lSwapAmount = 5e18;
        _tokenA.mint(address(_stablePair), lSwapAmount);
        _stablePair.swap(int256(lSwapAmount), true, address(this), "");
        uint256 lStablePairOutput = _tokenB.balanceOf(address(this));

        _tokenA.mint(address(_constantProductPair), lSwapAmount);
        _constantProductPair.swap(int256(lSwapAmount), true, address(this), "");
        uint256 lConstantProductOutput = _tokenB.balanceOf(address(this)) - lStablePairOutput;

        // assert
        assertGt(lStablePairOutput, lConstantProductOutput);
    }

    function testSwap_VerySmallLiquidity(uint256 aAmtBToMint, uint256 aAmtCToMint, uint256 aSwapAmt) public
    {
        // assume
        uint256 lMinLiq = _stablePair.MINIMUM_LIQUIDITY();
        uint256 lAmtBToMint = bound(aAmtBToMint, lMinLiq / 2 + 1, lMinLiq);
        uint256 lAmtCToMint = bound(aAmtCToMint, lMinLiq / 2 + 1, lMinLiq);
        uint256 lSwapAmt = bound(aSwapAmt, 1, type(uint112).max - lAmtBToMint);

        // arrange
        StablePair lPair = StablePair(_createPair(address(_tokenB), address(_tokenC), 1));
        _tokenB.mint(address(lPair), lAmtBToMint);
        _tokenC.mint(address(lPair), lAmtCToMint);
        lPair.mint(address(this));

        // sanity
        assertGe(lPair.balanceOf(address(this)), 2);

        // act
        _tokenB.mint(address(lPair), lSwapAmt);
        uint256 lAmtOut = lPair.swap(int256(lSwapAmt), true, address(this), bytes(""));

        // assert
        uint256 lExpectedAmountOut = StableMath._getAmountOut(
            lSwapAmt, lAmtBToMint, lAmtCToMint, 1, 1, true, 3000, 2 * _stablePair.getCurrentAPrecise()
        );
        assertEq(lAmtOut, lExpectedAmountOut);
    }

    function testSwap_VeryLargeLiquidity(uint256 aSwapAmt) public
    {
        // assume
        uint256 lSwapAmt = bound(aSwapAmt, 1, 10e18);
        uint256 lAmtBToMint = type(uint112).max;
        uint256 lAmtCToMint = type(uint112).max - lSwapAmt;

        // arrange
        StablePair lPair = StablePair(_createPair(address(_tokenB), address(_tokenC), 1));
        _tokenB.mint(address(lPair), lAmtBToMint);
        _tokenC.mint(address(lPair), lAmtCToMint);
        lPair.mint(address(this));

        // act
        _tokenC.mint(address(lPair), lSwapAmt);
        uint256 lAmtOut = lPair.swap(-int256(lSwapAmt), true, address(this), bytes(""));

        // assert
        uint256 lExpectedAmountOut = StableMath._getAmountOut(
            lSwapAmt, lAmtBToMint, lAmtCToMint, 1, 1, false, 3000, 2 * _stablePair.getCurrentAPrecise()
        );
        assertEq(lAmtOut, lExpectedAmountOut);
    }

    function testSwap_DiffSwapFees(uint256 aSwapFee) public
    {
        // assume
        uint256 lSwapFee = bound(aSwapFee, 0, _stablePair.MAX_SWAP_FEE());

        // arrange
        StablePair lPair = StablePair(_createPair(address(_tokenC), address(_tokenD), 1));
        vm.prank(address(_factory));
        lPair.setCustomSwapFee(lSwapFee);
        _tokenC.mint(address(lPair), 100_000_000e18);
        _tokenD.mint(address(lPair), 120_000_000e6);
        lPair.mint(address(this));

        uint256 lSwapAmt = 10_000_000e6;
        _tokenD.mint(address(lPair), lSwapAmt);

        // act - tokenD is token0
        uint256 lAmtOut = lPair.swap(int256(lSwapAmt), true, address(this), bytes(""));

        uint256 lExpectedAmtOut = StableMath._getAmountOut(
            lSwapAmt, 120_000_000e6, 100_000_000e18, 1e12, 1, true, lSwapFee, 2 * lPair.getCurrentAPrecise()
        );

        // assert
        assertEq(lAmtOut, lExpectedAmtOut);
    }

    function testSwap_DiffAs(uint256 aAmpCoeff, uint256 aSwapAmt, uint256 aMintAmt) public
    {
        // assume
        uint256 lAmpCoeff = bound(aAmpCoeff, StableMath.MIN_A, StableMath.MAX_A);
        uint256 lSwapAmt = bound(aSwapAmt, 1e3, type(uint112).max / 2);
        uint256 lCMintAmt = bound(aMintAmt, 1e18, 10_000_000_000e18);
        uint256 lDMintAmt = bound(lCMintAmt, lCMintAmt / 1e12 / 1e3, lCMintAmt / 1e12 * 1e3);

        // arrange
        _factory.set(keccak256("ConstantProductPair::amplificationCoefficient"), bytes32(uint256(lAmpCoeff)));
        StablePair lPair = StablePair(_createPair(address(_tokenD), address(_tokenC), 1));

        // sanity
        assertEq(lPair.getCurrentA(), lAmpCoeff);

        _tokenC.mint(address(lPair), lCMintAmt);
        _tokenD.mint(address(lPair), lDMintAmt);
        lPair.mint(address(this));

        // act
        _tokenD.mint(address(lPair), lSwapAmt);
        lPair.swap(int256(lSwapAmt), true, address(this), bytes(""));

        // assert
        uint256 lExpectedOutput = StableMath._getAmountOut(
            lSwapAmt, lDMintAmt, lCMintAmt, 1e12, 1, true, lPair.swapFee(), 2 * lPair.getCurrentAPrecise()
        );
        assertEq(_tokenC.balanceOf(address(this)), lExpectedOutput);
    }

    function testBurn() public
    {
        // arrange
        vm.startPrank(_alice);
        uint256 lLpTokenBalance = _stablePair.balanceOf(_alice);
        uint256 lLpTokenTotalSupply = _stablePair.totalSupply();
        (uint256 lReserve0, uint256 lReserve1, ) = _stablePair.getReserves();
        address lToken0 = _stablePair.token0();

        // act
        _stablePair.transfer(address(_stablePair), _stablePair.balanceOf(_alice));
        _stablePair.burn(_alice);

        // assert
        uint256 lExpectedTokenAReceived;
        uint256 lExpectedTokenBReceived;
        if (lToken0 == address(_tokenA)) {
            lExpectedTokenAReceived = lLpTokenBalance * lReserve0 / lLpTokenTotalSupply;
            lExpectedTokenBReceived = lLpTokenBalance * lReserve1 / lLpTokenTotalSupply;
        }
        else {
            lExpectedTokenAReceived = lLpTokenBalance * lReserve1 / lLpTokenTotalSupply;
            lExpectedTokenBReceived = lLpTokenBalance * lReserve0 / lLpTokenTotalSupply;
        }

        assertEq(_stablePair.balanceOf(_alice), 0);
        assertGt(lExpectedTokenAReceived, 0);
        assertEq(_tokenA.balanceOf(_alice), lExpectedTokenAReceived);
        assertEq(_tokenB.balanceOf(_alice), lExpectedTokenBReceived);
    }

    function testBurn_SucceedEvenIfMintFeeReverts() public
    {
        // arrange - change some values to make iterative function algorithm not converge
        // I have tried changing the reserves, but no matter how extreme the values are,
        // StableMath._computeLiquidityFromAdjustedBalances would still converge
        // which is good for our contracts but not good for my attempt to break it
        uint192 lLastInvariant = 200e18;
        uint64 lLastInvariantAmp = 0;
        bytes32 lEncoded = bytes32(abi.encodePacked(lLastInvariantAmp, lLastInvariant));
        // hardcoding the slot for now as there is no way to access it publicly
        // this will break when we change the storage layout
        vm.store(address(_stablePair), bytes32(uint256(65551)), lEncoded);

        // ensure that the iterative function that _mintFee calls reverts with the adulterated values
        vm.prank(address(_stablePair));
        vm.expectRevert(stdError.arithmeticError);
        _stablePair.mintFee(100e18, 100e18);

        // act
        vm.prank(_alice);
        _stablePair.transfer(address(_stablePair), 1e18);
        // mintFee indeed reverted but burn still succeeded - this can be seen by examining the callstack
        (uint256 lAmount0, uint256 lAmount1) = _stablePair.burn(address(this)); // mintFee would fail in this call

        // assert
        assertEq(lAmount0, 0.5e18);
        assertEq(lAmount0, lAmount1);
        assertEq(_tokenA.balanceOf(address(this)), lAmount0);
        assertEq(_tokenB.balanceOf(address(this)), lAmount1);
    }

    function testRampA() public
    {
        // arrange
        uint64 lCurrentTimestamp = uint64(block.timestamp);
        uint64 lFutureATimestamp = lCurrentTimestamp + 3 days;
        uint64 lFutureAToSet = 5000;

        // act
        vm.expectEmit(true, true, true, true);
        emit RampA(1000 * uint64(StableMath.A_PRECISION), lFutureAToSet * uint64(StableMath.A_PRECISION), lCurrentTimestamp, lFutureATimestamp);
        _factory.rawCall(
            address(_stablePair),
            abi.encodeWithSignature("rampA(uint64,uint64)", lFutureAToSet, lFutureATimestamp),
            0
        );

        // assert
        (uint64 lInitialA, uint64 lFutureA, uint64 lInitialATime, uint64 lFutureATime) = _stablePair.ampData();
        assertEq(lInitialA, 1000 * uint64(StableMath.A_PRECISION));
        assertEq(_stablePair.getCurrentA(), 1000);
        assertEq(lFutureA, lFutureAToSet * uint64(StableMath.A_PRECISION));
        assertEq(lInitialATime, block.timestamp);
        assertEq(lFutureATime, lFutureATimestamp);
    }

    function testRampA_OnlyFactory() public
    {
        // act && assert
        vm.expectRevert("P: FORBIDDEN");
        _stablePair.rampA(100, uint64(block.timestamp + 10 days));
    }

    function testRampA_SetAtMinimum() public
    {
        // arrange
        uint64 lCurrentTimestamp = uint64(block.timestamp);
        uint64 lFutureATimestamp = lCurrentTimestamp + 500 days;
        uint64 lFutureAToSet = uint64(StableMath.MIN_A);

        // act
        _factory.rawCall(
            address(_stablePair),
            abi.encodeWithSignature("rampA(uint64,uint64)", lFutureAToSet, lFutureATimestamp),
            0
        );

        // assert
        (, uint64 lFutureA, , ) = _stablePair.ampData();
        assertEq(lFutureA / StableMath.A_PRECISION, lFutureAToSet);
    }

    function testRampA_SetAtMaximum() public
    {
        // arrange
        uint64 lCurrentTimestamp = uint64(block.timestamp);
        uint64 lFutureATimestamp = lCurrentTimestamp + 5 days;
        uint64 lFutureAToSet = uint64(StableMath.MAX_A);

        // act
        _factory.rawCall(
            address(_stablePair),
            abi.encodeWithSignature("rampA(uint64,uint64)", lFutureAToSet, lFutureATimestamp),
            0
        );

        // assert
        (, uint64 lFutureA, , ) = _stablePair.ampData();
        assertEq(lFutureA / StableMath.A_PRECISION, lFutureAToSet);
    }


    function testRampA_BreachMinimum() public
    {
        // arrange
        uint64 lCurrentTimestamp = uint64(block.timestamp);
        uint64 lFutureATimestamp = lCurrentTimestamp + 3 days;
        uint64 lFutureAToSet = uint64(StableMath.MIN_A) - 1;

        // act & assert
        vm.expectRevert("SP: INVALID_A");
        _factory.rawCall(
            address(_stablePair),
            abi.encodeWithSignature("rampA(uint64,uint64)", lFutureAToSet, lFutureATimestamp),
            0
        );
    }

    function testRampA_BreachMaximum() public
    {
        // arrange
        uint64 lCurrentTimestamp = uint64(block.timestamp);
        uint64 lFutureATimestamp = lCurrentTimestamp + 501 days;
        uint64 lFutureAToSet = uint64(StableMath.MAX_A) + 1;

        // act & assert
        vm.expectRevert("SP: INVALID_A");
        _factory.rawCall(
            address(_stablePair),
            abi.encodeWithSignature("rampA(uint64,uint64)", lFutureAToSet, lFutureATimestamp),
            0
        );
    }

    function testRampA_MaxSpeed() public
    {
        // arrange
        uint64 lCurrentTimestamp = uint64(block.timestamp);
        uint64 lFutureATimestamp = lCurrentTimestamp + 1 days;
        uint64 lFutureAToSet = _stablePair.getCurrentA() * 2;

        // act
        _factory.rawCall(
            address(_stablePair),
            abi.encodeWithSignature("rampA(uint64,uint64)", lFutureAToSet, lFutureATimestamp),
            0
        );

        // assert
        (, uint64 lFutureA, , ) = _stablePair.ampData();
        assertEq(lFutureA, lFutureAToSet * StableMath.A_PRECISION);
    }

    function testRampA_BreachMaxSpeed() public
    {
        // arrange
        uint64 lCurrentTimestamp = uint64(block.timestamp);
        uint64 lFutureATimestamp = lCurrentTimestamp + 2 days - 1;
        uint64 lFutureAToSet = _stablePair.getCurrentA() * 4;

        // act & assert
        vm.expectRevert("SP: AMP_RATE_TOO_HIGH");
        _factory.rawCall(
            address(_stablePair),
            abi.encodeWithSignature("rampA(uint64,uint64)", lFutureAToSet, lFutureATimestamp),
            0
        );
    }

    function testStopRampA() public
    {
        // arrange
        uint64 lCurrentTimestamp = uint64(block.timestamp);
        uint64 lFutureATimestamp = lCurrentTimestamp + 3 days;
        uint64 lFutureAToSet = 5000;
        _factory.rawCall(
            address(_stablePair),
            abi.encodeWithSignature("rampA(uint64,uint64)", lFutureAToSet, lFutureATimestamp),
            0
        );

        vm.warp(lFutureATimestamp);

        // act
        _factory.rawCall(
            address(_stablePair),
            abi.encodeWithSignature("stopRampA()"),
            0
        );

        // assert
        (uint64 lInitialA, uint64 lFutureA, uint64 lInitialATime, uint64 lFutureATime) = _stablePair.ampData();
        assertEq(lInitialA, lFutureAToSet * uint64(StableMath.A_PRECISION));
        assertEq(lFutureA, lFutureAToSet * uint64(StableMath.A_PRECISION));
        assertEq(lInitialATime, lFutureATimestamp);
        assertEq(lFutureATime, lFutureATimestamp);
    }

    function testStopRampA_OnlyFactory() public
    {
        // act & assert
        vm.expectRevert("P: FORBIDDEN");
        _stablePair.stopRampA();
    }

    function testStopRampA_Early(uint256 aFutureA) public
    {
        // assume
        uint64 lFutureAToSet = uint64(bound(aFutureA, StableMath.MIN_A, StableMath.MAX_A));

        // arrange
        uint64 lInitialA = _stablePair.getCurrentA();
        uint64 lCurrentTimestamp = uint64(block.timestamp);
        uint64 lFutureATimestamp = lCurrentTimestamp + 1000 days;
        _factory.rawCall(
            address(_stablePair),
            abi.encodeWithSignature("rampA(uint64,uint64)", lFutureAToSet, lFutureATimestamp),
            0
        );

        _stepTime(lFutureATimestamp / 2);

        // act
        _factory.rawCall(
            address(_stablePair),
            abi.encodeWithSignature("stopRampA()"),
            0
        );

        // assert
        uint256 lTotalADiff = lFutureAToSet > lInitialA ? lFutureAToSet - lInitialA : lInitialA - lFutureAToSet;
        uint256 lActualADiff = lFutureAToSet > lInitialA ? _stablePair.getCurrentA() - lInitialA : lInitialA - _stablePair.getCurrentA();
        assertApproxEqAbs(lActualADiff, lTotalADiff / 2, 1);
        (uint64 lNewInitialA, uint64 lNewFutureA, uint64 lInitialATime, uint64 lFutureATime) = _stablePair.ampData();
        assertEq(lNewInitialA, lNewFutureA);
        assertEq(lInitialATime, block.timestamp);
        assertEq(lFutureATime, block.timestamp);
    }

    function testStopRampA_Late(uint256 aFutureA) public
    {
        // assume
        uint64 lFutureAToSet = uint64(bound(aFutureA, StableMath.MIN_A, StableMath.MAX_A));

        // arrange
        uint64 lCurrentTimestamp = uint64(block.timestamp);
        uint64 lFutureATimestamp = lCurrentTimestamp + 1000 days;
        _factory.rawCall(
            address(_stablePair),
            abi.encodeWithSignature("rampA(uint64,uint64)", lFutureAToSet, lFutureATimestamp),
            0
        );

        _stepTime(lFutureATimestamp + 10 days);

        // act
        _factory.rawCall(
            address(_stablePair),
            abi.encodeWithSignature("stopRampA()"),
            0
        );

        // assert
        assertEq(_stablePair.getCurrentA(), lFutureAToSet);
        (uint64 lNewInitialA, uint64 lNewFutureA, uint64 lInitialATime, uint64 lFutureATime) = _stablePair.ampData();
        assertEq(_stablePair.getCurrentA(), lNewInitialA / StableMath.A_PRECISION);
        assertEq(lNewInitialA, lNewFutureA);
        assertEq(lInitialATime, block.timestamp);
        assertEq(lFutureATime, block.timestamp);
    }

    function testGetCurrentA() public
    {
        // arrange
        uint64 lCurrentTimestamp = uint64(block.timestamp);
        uint64 lFutureATimestamp = lCurrentTimestamp + 3 days;
        uint64 lFutureAToSet = 5000;

        // act
        _factory.rawCall(
            address(_stablePair),
            abi.encodeWithSignature("rampA(uint64,uint64)", lFutureAToSet, lFutureATimestamp),
            0
        );

        // assert
        assertEq(_stablePair.getCurrentA(), 1000);

        // warp to the midpoint between the initialATime and futureATime
        vm.warp((lFutureATimestamp + block.timestamp) / 2);
        assertEq(_stablePair.getCurrentA(), (1000 + lFutureAToSet) / 2);

        // warp to the end
        vm.warp(lFutureATimestamp);
        assertEq(_stablePair.getCurrentA(), lFutureAToSet);
    }

    function testRampA_SwappingDuringRampingUp(uint256 aSeed, uint64 aFutureA, uint64 aDuration, uint128 aSwapAmount) public
    {
        // arrange
        uint64 lFutureAToSet = uint64(bound(aFutureA, _stablePair.getCurrentA(), StableMath.MAX_A));
        uint256 lMinRampDuration = lFutureAToSet / _stablePair.getCurrentA() * 1 days;
        uint256 lMaxRampDuration = 30 days; // 1 month
        uint64 lCurrentTimestamp = uint64(block.timestamp);
        uint64 lFutureATimestamp = lCurrentTimestamp + uint64(bound(aDuration, lMinRampDuration, lMaxRampDuration));
        uint256 lAmountToSwap = aSwapAmount / 2;

        // act
        _factory.rawCall(
            address(_stablePair),
            abi.encodeWithSignature("rampA(uint64,uint64)", lFutureAToSet, lFutureATimestamp),
            0
        );

        uint256 lAmountOutBeforeRamp = _stablePair.getAmountOut(address(_tokenA), lAmountToSwap);
        uint64 lRemainingTime = lFutureATimestamp - lCurrentTimestamp;

        uint64 lCheck1 = uint64(bound(aSeed, 0, lRemainingTime));
        skip(lCheck1);
        uint256 lAmountOutT1 = _stablePair.getAmountOut(address(_tokenA), lAmountToSwap);

        lRemainingTime -= lCheck1;
        uint64 lCheck2 = uint64(bound(uint256(keccak256(abi.encode(lCheck1))), 0, lRemainingTime));
        skip(lCheck2);
        uint256 lAmountOutT2 = _stablePair.getAmountOut(address(_tokenA), lAmountToSwap);

        lRemainingTime -= lCheck2;
        uint64 lCheck3 = uint64(bound(uint256(keccak256(abi.encode(lCheck2))), 0, lRemainingTime));
        skip(lCheck3);
        uint256 lAmountOutT3 = _stablePair.getAmountOut(address(_tokenA), lAmountToSwap);

        lRemainingTime -= lCheck3;
        skip(lRemainingTime);
        uint256 lAmountOutT4 = _stablePair.getAmountOut(address(_tokenA), lAmountToSwap);

        // assert - output amount over time should be increasing or be within 1 due to rounding error
        assertTrue(lAmountOutT1 >= lAmountOutBeforeRamp || MathUtils.within1(lAmountOutT1, lAmountOutBeforeRamp));
        assertTrue(lAmountOutT2 >= lAmountOutT1         || MathUtils.within1(lAmountOutT2, lAmountOutT1));
        assertTrue(lAmountOutT3 >= lAmountOutT2         || MathUtils.within1(lAmountOutT3, lAmountOutT2));
        assertTrue(lAmountOutT4 >= lAmountOutT3         || MathUtils.within1(lAmountOutT4, lAmountOutT3));
    }

    function testRampA_SwappingDuringRampingDown(uint256 aSeed, uint64 aFutureA, uint64 aDuration, uint128 aSwapAmount) public
    {
        // arrange
        uint64 lFutureAToSet = uint64(bound(aFutureA, StableMath.MIN_A, _stablePair.getCurrentA()));
        uint256 lMinRampDuration = _stablePair.getCurrentA() / lFutureAToSet * 1 days;
        uint256 lMaxRampDuration = 1000 days;
        uint64 lCurrentTimestamp = uint64(block.timestamp);
        uint64 lFutureATimestamp = lCurrentTimestamp + uint64(bound(aDuration, lMinRampDuration, lMaxRampDuration));
        uint256 lAmountToSwap = aSwapAmount / 2;

         // act
        _factory.rawCall(
            address(_stablePair),
            abi.encodeWithSignature("rampA(uint64,uint64)", lFutureAToSet, lFutureATimestamp),
            0
        );

        uint256 lAmountOutBeforeRamp = _stablePair.getAmountOut(address(_tokenA), lAmountToSwap);
        uint64 lRemainingTime = lFutureATimestamp - lCurrentTimestamp;

        uint64 lCheck1 = uint64(bound(aSeed, 0, lRemainingTime));
        skip(lCheck1);
        uint256 lAmountOutT1 = _stablePair.getAmountOut(address(_tokenA), lAmountToSwap);

        lRemainingTime -= lCheck1;
        uint64 lCheck2 = uint64(bound(uint256(keccak256(abi.encode(lCheck1))), 0, lRemainingTime));
        skip(lCheck2);
        uint256 lAmountOutT2 = _stablePair.getAmountOut(address(_tokenA), lAmountToSwap);

        lRemainingTime -= lCheck2;
        uint64 lCheck3 = uint64(bound(uint256(keccak256(abi.encode(lCheck1))), 0, lRemainingTime));
        skip(lCheck3);
        uint256 lAmountOutT3 = _stablePair.getAmountOut(address(_tokenA), lAmountToSwap);

        lRemainingTime -= lCheck3;
        skip(lRemainingTime);
        uint256 lAmountOutT4 = _stablePair.getAmountOut(address(_tokenA), lAmountToSwap);

        // assert - output amount over time should be decreasing or within 1 due to rounding error
        assertTrue(lAmountOutT1 <= lAmountOutBeforeRamp || MathUtils.within1(lAmountOutT1, lAmountOutBeforeRamp));
        assertTrue(lAmountOutT2 <= lAmountOutT1         || MathUtils.within1(lAmountOutT2, lAmountOutT1));
        assertTrue(lAmountOutT3 <= lAmountOutT2         || MathUtils.within1(lAmountOutT3, lAmountOutT2));
        assertTrue(lAmountOutT4 <= lAmountOutT3         || MathUtils.within1(lAmountOutT4, lAmountOutT3));
    }

    // inspired from saddle's test case, which is testing for this vulnerability
    // https://medium.com/@peter_4205/curve-vulnerability-report-a1d7630140ec
    function testAttackWhileRampingDown_ShortInterval() public
    {
        // arrange
        uint64 lNewA = 400;
        vm.startPrank(address(_factory));
        _stablePair.rampA(lNewA, uint64(block.timestamp + 4 days));
        _stablePair.setCustomSwapFee(100); // 1 bp
        vm.stopPrank();

        // swap 70e18 of tokenA to tokenB to cause a large imbalance
        uint256 lSwapAmt = 70e18;
        _tokenA.mint(address(_stablePair), lSwapAmt);
        uint256 lAmtOut = _stablePair.swap(int256(lSwapAmt), true, address(this), bytes(""));

        assertEq(lAmtOut, 69897580651885320277);
        assertEq(_tokenB.balanceOf(address(this)), 69897580651885320277);

        // Pool is imbalanced! Now trades from tokenB -> tokenA may be profitable in small sizes
        // tokenA balance in the pool  : 170e18
        // tokenB balance in the pool : 30.10e18
        (uint112 lReserve0, uint112 lReserve1, )  = _stablePair.getReserves();
        assertEq(lReserve0, 170e18);
        assertEq(lReserve1, 30102419348114679723);

        _stepTime(20 minutes);
        assertEq(_stablePair.getCurrentA(), 997);

        // act - now attacker swaps from tokenB to tokenA
        _tokenB.transfer(address(_stablePair), 69897580651885320277);
        _stablePair.swap(-69897580651885320277, true, address(this), bytes(""));

        // assert
        // the attacker did not get more than what he started with
        assertLt(_tokenA.balanceOf(address(this)), lSwapAmt);
        // the pool was not worse off
        (lReserve0, lReserve1, ) = _stablePair.getReserves();
        assertGt(lReserve0, INITIAL_MINT_AMOUNT);
        assertEq(lReserve1, INITIAL_MINT_AMOUNT);
    }

    // this is to simulate a sudden large A change, without trades having taken place in between
    // this will not happen in our case as A is changed gently over a period not suddenly
    function testAttackWhileRampingDown_LongInterval() public
    {
        // arrange
        uint64 lNewA = 400;
        vm.startPrank(address(_factory));
        _stablePair.rampA(lNewA, uint64(block.timestamp + 4 days));
        _stablePair.setCustomSwapFee(100); // 1 bp
        vm.stopPrank();

        // swap 70e18 of tokenA to tokenB to cause a large imbalance
        uint256 lSwapAmt = 70e18;
        _tokenA.mint(address(_stablePair), lSwapAmt);
        uint256 lAmtOut = _stablePair.swap(int256(lSwapAmt), true, address(this), bytes(""));

        assertEq(lAmtOut, 69897580651885320277);
        assertEq(_tokenB.balanceOf(address(this)), 69897580651885320277);

        // Pool is imbalanced! Now trades from tokenB -> tokenA may be profitable in small sizes
        // tokenA balance in the pool  : 170e18
        // tokenB balance in the pool : 30.10e18
        (uint112 lReserve0, uint112 lReserve1, )  = _stablePair.getReserves();
        assertEq(lReserve0, 170e18);
        assertEq(lReserve1, 30102419348114679723);

        // to simulate that no trades have taken place throughout the process of ramping down
        // or rapid A change
        _stepTime(4 days);
        assertEq(_stablePair.getCurrentA(), 400);

        // act - now attacker swaps from tokenB to tokenA
        _tokenB.transfer(address(_stablePair), 69897580651885320277);
        _stablePair.swap(-69897580651885320277, true, address(this), bytes(""));

        // assert - the attack was successful
        // the attacker got more than what he started with
        assertGt(_tokenA.balanceOf(address(this)), lSwapAmt);
        // the pool is worse off by 0.13%
        (lReserve0, lReserve1, ) = _stablePair.getReserves();
        assertEq(lReserve0, 99871702539906228887);
        assertEq(lReserve1, INITIAL_MINT_AMOUNT);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    ORACLE
    //////////////////////////////////////////////////////////////////////////*/

    function testOracle_NoWriteInSameTimestamp() public
    {
        // arrange
        uint16 lInitialIndex = _stablePair.index();
        uint256 lAmountToSwap = 1e17;

        // act
        _tokenA.mint(address(_stablePair), lAmountToSwap);
        _stablePair.swap(int256(lAmountToSwap), true, address(this), "");

        vm.prank(_alice);
        _stablePair.transfer(address(_stablePair), 1e18);
        _stablePair.burn(address(this));

        _stablePair.sync();

        // assert
        uint16 lFinalIndex = _stablePair.index();
        assertEq(lFinalIndex, lInitialIndex);
    }

    function testOracle_WrapsAroundAfterFull() public
    {
        // arrange
        uint256 lAmountToSwap = 1e15;
        uint256 lMaxObservations = 2 ** 16;

        // act
        for (uint i = 0; i < lMaxObservations + 4; ++i) {
            _stepTime(5);
            _tokenA.mint(address(_stablePair), lAmountToSwap);
            _stablePair.swap(int256(lAmountToSwap), true, address(this), "");
        }

        // assert
        assertEq(_stablePair.index(), 3);
    }

    function testWriteObservations() external
    {
        // arrange
        // swap 1
        _stepTime(1);
        (uint256 lReserve0, uint256 lReserve1, ) = _stablePair.getReserves();
        _tokenA.mint(address(_stablePair), 5e18);
        _stablePair.swap(5e18, true, address(this), "");

        // swap 2
        _stepTime(1);
        (lReserve0, lReserve1, ) = _stablePair.getReserves();
        _tokenA.mint(address(_stablePair), 5e18);
        _stablePair.swap(5e18, true, address(this), "");

        // sanity
        assertEq(_stablePair.index(), 1);

        (int112 lLogPriceAcc, int112 lLogLiqAcc, uint32 lTimestamp) = _stablePair.observations(0);
        assertTrue(lLogPriceAcc == 0);
        assertTrue(lLogLiqAcc != 0);
        assertTrue(lTimestamp != 0);

        (lLogPriceAcc, lLogLiqAcc, lTimestamp) = _stablePair.observations(1);
        assertTrue(lLogPriceAcc != 0);
        assertTrue(lLogLiqAcc != 0);
        assertTrue(lTimestamp != 0);

        // act
        _writeObservation(_stablePair, 0, int112(1337), int112(-1337), uint32(666));

        // assert
        (lLogPriceAcc, lLogLiqAcc, lTimestamp) = _stablePair.observations(0);
        assertEq(lLogPriceAcc, int112(1337));
        assertEq(lLogLiqAcc, int112(-1337));
        assertEq(lTimestamp, uint32(666));

        (lLogPriceAcc, lLogLiqAcc, lTimestamp) = _stablePair.observations(1);
        assertTrue(lLogPriceAcc != 0);
        assertTrue(lLogLiqAcc != 0);
        assertTrue(lTimestamp != 0);
    }

    function testOracle_OverflowAccPrice() public
    {
        // arrange - make the last observation close to overflowing
        _writeObservation(
            _stablePair,
            _stablePair.index(),
            type(int112).max,
            0,
            uint32(block.timestamp)
        );
        (int112 lPrevAccPrice, , ) = _stablePair.observations(_stablePair.index());

        // act
        uint256 lAmountToSwap = 5e18;
        _tokenB.mint(address(_stablePair), lAmountToSwap);
        _stablePair.swap(-int256(lAmountToSwap), true, address(this), "");

        _stepTime(5);
        _stablePair.sync();

        // assert - when it overflows it goes from a very positive number to a very negative number
        (int112 lCurrAccPrice, , ) = _stablePair.observations(_stablePair.index());
        assertLt(lCurrAccPrice, lPrevAccPrice);
    }

    function testOracle_OverflowAccLiquidity() public
    {
        // arrange
        _writeObservation(
            _stablePair,
            _stablePair.index(),
            0,
            type(int112).max,
            uint32(block.timestamp)
        );
        (, int112 lPrevAccLiq, ) = _stablePair.observations(_stablePair.index());

        // act
        _stepTime(5);
        _stablePair.sync();

        // assert
        (, int112 lCurrAccLiq, ) = _stablePair.observations(_stablePair.index());
        assertLt(lCurrAccLiq, lPrevAccLiq);
    }

    function testOracle_CorrectPrice() public
    {
        // arrange
        uint256 lAmountToSwap = 1e18;
        _stepTime(5);

        // act
        _tokenA.mint(address(_stablePair), lAmountToSwap);
        _stablePair.swap(int256(lAmountToSwap), true, address(this), "");

        (uint256 lReserve0_1, uint256 lReserve1_1, ) = _stablePair.getReserves();
        (uint256 lPrice1, )= StableOracleMath.calcSpotPrice(_stablePair.getCurrentAPrecise(), lReserve0_1, lReserve1_1);
        _stepTime(5);

        _tokenA.mint(address(_stablePair), lAmountToSwap);
        _stablePair.swap(int256(lAmountToSwap), true, address(this), "");
        (uint256 lReserve0_2, uint256 lReserve1_2, ) = _stablePair.getReserves();
        (uint256 lPrice2, )= StableOracleMath.calcSpotPrice(_stablePair.getCurrentAPrecise(), lReserve0_2, lReserve1_2);

        _stepTime(5);
        _stablePair.sync();

        // assert
        (int lAccPrice1, , uint32 lTimestamp1) = _stablePair.observations(0);
        (int lAccPrice2, , uint32 lTimestamp2) = _stablePair.observations(1);
        (int lAccPrice3, , uint32 lTimestamp3) = _stablePair.observations(2);

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

    function testOracle_SimplePrices() external
    {
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
        (uint256 lReserve0_1, uint256 lReserve1_1, ) = _stablePair.getReserves();
        (uint256 lSpotPrice1, ) = StableOracleMath.calcSpotPrice(_stablePair.getCurrentAPrecise(), lReserve0_1, lReserve1_1);
        _stepTime(10);

        // price = 0.0000936563
        _tokenA.mint(address(_stablePair), 200e18);
        _stablePair.swap(200e18, true, _bob, "");
        (uint256 lReserve0_2, uint256 lReserve1_2, ) = _stablePair.getReserves();
        (uint256 lSpotPrice2, ) = StableOracleMath.calcSpotPrice(_stablePair.getCurrentAPrecise(), lReserve0_2, lReserve1_2);
        _stepTime(10);
        _stablePair.sync();

        // assert
        (int lAccPrice1, , uint32 lTimestamp1) = _stablePair.observations(0);
        (int lAccPrice2, , uint32 lTimestamp2) = _stablePair.observations(1);
        (int lAccPrice3, , uint32 lTimestamp3) = _stablePair.observations(2);

        assertEq(lAccPrice1, LogCompression.toLowResLog(1e18) * 10, "1");
        assertEq(lAccPrice2, LogCompression.toLowResLog(1e18) * 10 + LogCompression.toLowResLog(lSpotPrice1) * 10, "2");
        assertEq(
            lAccPrice3,
            LogCompression.toLowResLog(1e18) * 10
            + LogCompression.toLowResLog(lSpotPrice1) * 10
            + LogCompression.toLowResLog(lSpotPrice2) * 10,
            "3"
        );

        // Price for observation window 1-2
        assertApproxEqRel(
            LogCompression.fromLowResLog((lAccPrice2 - lAccPrice1) / int32(lTimestamp2 - lTimestamp1)),
            lSpotPrice1,
            0.0001e18
        );
        // Price for observation window 2-3
        assertApproxEqRel(
            LogCompression.fromLowResLog((lAccPrice3 - lAccPrice2) / int32(lTimestamp3 - lTimestamp2)),
            lSpotPrice2,
            0.0001e18
        );
        // Price for observation window 1-3
        assertApproxEqRel(
            LogCompression.fromLowResLog((lAccPrice3 - lAccPrice1) / int32(lTimestamp3 - lTimestamp1)),
            Math.sqrt(lSpotPrice1 * lSpotPrice2),
            0.0001e18
        );
    }

    function testOracle_CorrectLiquidity() public
    {
        // arrange
        uint256 lAmountToBurn = 1e18;

        // act
        _stepTime(5);
        vm.prank(_alice);
        _stablePair.transfer(address(_stablePair), lAmountToBurn);
        _stablePair.burn(address(this));

        // assert
        (, int256 lAccLiq, ) = _stablePair.observations(_stablePair.index());
        uint256 lAverageLiq = LogCompression.fromLowResLog(lAccLiq / 5);
        // we check that it is within 0.01% of accuracy
        assertApproxEqRel(lAverageLiq, INITIAL_MINT_AMOUNT * 2, 0.0001e18);

        // act
        _stepTime(5);
        _stablePair.sync();

        // assert
        (, int256 lAccLiq2, ) = _stablePair.observations(_stablePair.index());
        uint256 lAverageLiq2 = LogCompression.fromLowResLog((lAccLiq2 - lAccLiq) / 5);
        assertApproxEqRel(lAverageLiq2, INITIAL_MINT_AMOUNT * 2 - lAmountToBurn, 0.0001e18);
    }

    function testOracle_LiquidityAtMaximum() public
    {
        // arrange
        uint256 lLiquidityToAdd = type(uint112).max - INITIAL_MINT_AMOUNT;
        _stepTime(5);
        _tokenA.mint(address(_stablePair), lLiquidityToAdd);
        _tokenB.mint(address(_stablePair), lLiquidityToAdd);
        _stablePair.mint(address(this));

        // sanity
        (uint112 lReserve0, uint112 lReserve1, ) = _stablePair.getReserves();
        assertEq(lReserve0, type(uint112).max);
        assertEq(lReserve1, type(uint112).max);

        // act
        _stepTime(5);
        _stablePair.sync();

        // assert
        uint256 lTotalSupply = _stablePair.totalSupply();
        assertEq(lTotalSupply, uint256(type(uint112).max) * 2);

        (, int112 lAccLiq1, ) = _stablePair.observations(0);
        (, int112 lAccLiq2, ) = _stablePair.observations(_stablePair.index());
        assertApproxEqRel(uint256(type(uint112).max) * 2, LogCompression.fromLowResLog( (lAccLiq2 - lAccLiq1) / 5), 0.0001e18);
    }
}
