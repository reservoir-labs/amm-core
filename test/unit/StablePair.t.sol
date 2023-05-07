pragma solidity ^0.8.0;

import "test/__fixtures/BaseTest.sol";
import "test/__fixtures/MintableERC20.sol";
import { Math } from "test/__fixtures/Math.sol";

import { MathUtils } from "src/libraries/MathUtils.sol";
import { LogCompression } from "src/libraries/LogCompression.sol";
import { StableOracleMath } from "src/libraries/StableOracleMath.sol";
import { StableMath } from "src/libraries/StableMath.sol";
import { Observation } from "src/ReservoirPair.sol";
import { StablePair, AmplificationData, IReservoirCallee } from "src/curve/stable/StablePair.sol";
import { GenericFactory } from "src/GenericFactory.sol";
import { AssetManagerReenter } from "test/__mocks/AssetManagerReenter.sol";

contract StablePairTest is BaseTest {
    using FactoryStoreLib for GenericFactory;

    event RampA(uint64 initialA, uint64 futureA, uint64 initialTime, uint64 futureTime);
    event Burn(address indexed sender, uint256 amount0, uint256 amount1);

    // for testing reentrancy
    AssetManagerReenter private _reenter = new AssetManagerReenter();

    function(address, int256, int256, bytes calldata) internal private _validateCallback;

    function reservoirCall(address aSwapper, int256 lToken0, int256 lToken1, bytes calldata aData) external {
        _validateCallback(aSwapper, lToken0, lToken1, aData);
    }

    function _calculateConstantProductOutput(uint256 aReserveIn, uint256 aReserveOut, uint256 aTokenIn, uint256 aFee)
        private
        view
        returns (uint256 rExpectedOut)
    {
        uint256 MAX_FEE = _stablePair.FEE_ACCURACY();
        uint256 lAmountInWithFee = aTokenIn * (MAX_FEE - aFee);
        uint256 lNumerator = lAmountInWithFee * aReserveOut;
        uint256 lDenominator = aReserveIn * MAX_FEE + lAmountInWithFee;

        rExpectedOut = lNumerator / lDenominator;
    }

    function _getToken0Token1(address aTokenA, address aTokenB)
        private
        pure
        returns (address rToken0, address rToken1)
    {
        (rToken0, rToken1) = aTokenA < aTokenB ? (aTokenA, aTokenB) : (aTokenB, aTokenA);
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
        uint256 lLpTokenTotalSupply = _stablePair.totalSupply();
        (uint256 lReserve0, uint256 lReserve1,,) = _stablePair.getReserves();
        uint256 lOldLiquidity = lReserve0 + lReserve1;
        uint256 lLiquidityToAdd = 5e18;

        // act
        _tokenA.mint(address(_stablePair), lLiquidityToAdd);
        _tokenB.mint(address(_stablePair), lLiquidityToAdd);
        _stablePair.mint(address(this));

        // assert
        // this works only because the pools are balanced. When the pool is imbalanced the calculation will differ
        uint256 lAdditionalLpTokens = ((Constants.INITIAL_MINT_AMOUNT + lLiquidityToAdd) * 2 - lOldLiquidity)
            * lLpTokenTotalSupply / lOldLiquidity;
        assertEq(_stablePair.balanceOf(address(this)), lAdditionalLpTokens);
    }

    function testMint_Reenter() external {
        // arrange
        vm.prank(address(_factory));
        _stablePair.setManager(_reenter);

        // act & assert
        vm.expectRevert("REENTRANCY");
        _stablePair.mint(address(this));
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
        uint256 lAmountAToMint = 1e18;
        uint256 lAmountBToMint = 100e18;

        _tokenA.mint(address(_stablePair), lAmountAToMint);
        _tokenB.mint(address(_stablePair), lAmountBToMint);

        // act
        _stablePair.mint(address(this));

        // assert
        assertLt(_stablePair.balanceOf(address(this)), lAmountAToMint + lAmountBToMint);
    }

    // This test case demonstrates that if a LP provider provides liquidity in non-optimal proportions
    // and then removes liquidity, they would be worse off had they just swapped it instead
    // and thus the mint-burn mechanism cannot be gamed into getting a better price
    function testMint_NonOptimalProportion_ThenBurn() public {
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

    function testMint_PlatformFeeOff() external {
        // arrange
        vm.prank(address(_factory));
        _stablePair.setCustomPlatformFee(0);

        // sanity
        assertEq(_stablePair.platformFee(), 0);

        // act
        _tokenA.mint(address(_stablePair), Constants.INITIAL_MINT_AMOUNT);
        _tokenB.mint(address(_stablePair), Constants.INITIAL_MINT_AMOUNT);
        _stablePair.mint(address(this));

        // assert
        assertEq(_stablePair.balanceOf(address(this)), 2 * Constants.INITIAL_MINT_AMOUNT);
    }

    function testMint_WhenRampingA(uint256 aFutureA) external {
        // assume - for ramping up or down from Constants.DEFAULT_AMP_COEFF
        uint64 lFutureAToSet = uint64(bound(aFutureA, 100, 5000));
        vm.assume(lFutureAToSet != Constants.DEFAULT_AMP_COEFF);
        uint64 lFutureATimestamp = uint64(block.timestamp) + 5 days;

        // arrange
        vm.prank(address(_factory));
        _stablePair.rampA(lFutureAToSet, lFutureATimestamp);
        uint256 lBefore = vm.snapshot();

        // act
        vm.warp(lFutureATimestamp / 2);
        _tokenA.mint(address(_stablePair), 5e18);
        _tokenB.mint(address(_stablePair), 10e18);
        _stablePair.mint(address(this));
        uint256 lLpTokens1 = _stablePair.balanceOf(address(this));

        vm.revertTo(lBefore);

        vm.warp(lFutureATimestamp);
        _tokenA.mint(address(_stablePair), 5e18);
        _tokenB.mint(address(_stablePair), 10e18);
        _stablePair.mint(address(this));
        uint256 lLpTokens2 = _stablePair.balanceOf(address(this));

        // assert
        if (lFutureAToSet > Constants.DEFAULT_AMP_COEFF) {
            assertGt(lLpTokens2, lLpTokens1);
        } else if (lFutureAToSet < Constants.DEFAULT_AMP_COEFF) {
            assertLt(lLpTokens2, lLpTokens1);
        }
    }

    function testMintFee_WhenRampingA_PoolBalanced(uint256 aFutureA) public {
        // assume - for ramping up or down from Constants.DEFAULT_AMP_COEFF
        uint64 lFutureAToSet = uint64(bound(aFutureA, 100, 5000));
        vm.assume(lFutureAToSet != Constants.DEFAULT_AMP_COEFF);

        // arrange
        StablePair lOtherPair = StablePair(_createPair(address(_tokenA), address(_tokenC), 1));
        _tokenA.mint(address(lOtherPair), Constants.INITIAL_MINT_AMOUNT);
        _tokenC.mint(address(lOtherPair), Constants.INITIAL_MINT_AMOUNT);
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
        (uint256 lReserve0_S, uint256 lReserve1_S,,) = _stablePair.getReserves();
        (uint256 lReserve0_O, uint256 lReserve1_O,,) = lOtherPair.getReserves();
        assertEq(lReserve0_S, lReserve0_O);
        assertEq(lReserve1_S, lReserve1_O);

        (uint256 lTotalSupply1,) = _stablePair.burn(address(this));
        (uint256 lTotalSupply2,) = lOtherPair.burn(address(this));

        // assert - even after the difference in A, we expect the platformFee received (LP tokens) to be the same
        assertEq(_stablePair.balanceOf(address(_platformFeeTo)), lOtherPair.balanceOf(address(_platformFeeTo)));
        assertEq(lTotalSupply1, lTotalSupply2);
    }

    function testMintFee_WhenRampingA_PoolUnbalanced(uint256 aFutureA) public {
        // assume - for ramping up or down from Constants.DEFAULT_AMP_COEFF
        uint64 lFutureAToSet = uint64(bound(aFutureA, 100, 5000));
        vm.assume(lFutureAToSet != Constants.DEFAULT_AMP_COEFF);

        // arrange
        StablePair lOtherPair = StablePair(_createPair(address(_tokenA), address(_tokenC), 1));
        _tokenA.mint(address(lOtherPair), Constants.INITIAL_MINT_AMOUNT);
        _tokenC.mint(address(lOtherPair), Constants.INITIAL_MINT_AMOUNT);
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
        (uint256 lReserve0_S, uint256 lReserve1_S,,) = _stablePair.getReserves();
        (uint256 lReserve0_O, uint256 lReserve1_O,,) = lOtherPair.getReserves();
        assertEq(lReserve0_S, lReserve0_O);
        assertEq(lReserve1_S, lReserve1_O);

        (uint256 lTotalSupply1,) = _stablePair.burn(address(this));
        (uint256 lTotalSupply2,) = lOtherPair.burn(address(this));

        // assert - even after the difference in A, we expect the platformFee received (LP tokens) to be the same
        assertGt(_stablePair.balanceOf(address(_platformFeeTo)), 0);
        assertGt(lOtherPair.balanceOf(address(_platformFeeTo)), 0);
        assertEq(_stablePair.balanceOf(address(_platformFeeTo)), lOtherPair.balanceOf(address(_platformFeeTo)));
        assertEq(lTotalSupply1, lTotalSupply2);
    }

    function _calcExpectedPlatformFee(
        uint256 aPlatformFee,
        StablePair aPair,
        uint256 aReserve0,
        uint256 aReserve1,
        uint256 aTotalSupply,
        uint256 aOldLiq
    ) internal view returns (uint256 rExpectedPlatformFee, uint256 rGrowthInLiq) {
        (uint256 lReserveC, uint256 lReserveD) =
            aPair.token0() == _tokenC ? (aReserve0, aReserve1) : (aReserve1, aReserve0);
        uint256 lNewLiq = StableMath._computeLiquidityFromAdjustedBalances(
            lReserveD * 1e12, lReserveC, 2 * aPair.getCurrentAPrecise()
        );

        rGrowthInLiq = lNewLiq - aOldLiq;
        rExpectedPlatformFee = aTotalSupply * rGrowthInLiq * aPlatformFee
            / ((aPair.FEE_ACCURACY() - aPlatformFee) * lNewLiq + aPlatformFee * aOldLiq);
    }

    function testMintFee_DiffPlatformFees(uint256 aPlatformFee) public {
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
        for (uint256 i; i < 20; ++i) {
            _tokenD.mint(address(lPair), lDSwapAmt);
            lPair.swap(
                lPair.token0() == _tokenD ? int256(lDSwapAmt) : -int256(lDSwapAmt), true, address(this), bytes("")
            );

            _tokenC.mint(address(lPair), lCSwapAmt);
            lPair.swap(
                lPair.token0() == _tokenC ? int256(lCSwapAmt) : -int256(lCSwapAmt), true, address(this), bytes("")
            );
        }

        (uint256 lReserve0, uint256 lReserve1,,) = lPair.getReserves();
        uint256 lTotalSupply = lPair.totalSupply();

        // act
        lPair.transfer(address(lPair), 1e18);
        lPair.burn(address(this));

        // assert
        (uint256 lExpectedPlatformFee, uint256 lGrowthInLiq) =
            _calcExpectedPlatformFee(lPlatformFee, lPair, lReserve0, lReserve1, lTotalSupply, lOldLiq);
        assertEq(lPair.balanceOf(_platformFeeTo), lExpectedPlatformFee);
        if (aPlatformFee > 0) {
            assertGt(lPair.balanceOf(_platformFeeTo), 0);
        }
        assertApproxEqRel(
            lExpectedPlatformFee * 1e18 / lGrowthInLiq, lPlatformFee * 1e18 / lPair.FEE_ACCURACY(), 0.006e18
        );
    }

    function testSwap() public {
        // act
        uint256 lAmountToSwap = 5e18;
        _tokenA.mint(address(_stablePair), lAmountToSwap);
        uint256 lAmountOut = _stablePair.swap(int256(lAmountToSwap), true, address(this), "");

        // assert
        assertEq(lAmountOut, _tokenB.balanceOf(address(this)));
    }

    function _reenterSwap(address aSwapper, int256 aToken0, int256 aToken1, bytes calldata aData) internal {
        assertEq(aSwapper, address(this));
        assertEq(aToken0, -1e18);
        assertApproxEqRel(aToken1, 1e18, 0.002e18);
        assertEq(aData, bytes(hex"00"));

        _stablePair.swap(1e18, true, address(this), "");
    }

    function testSwap_Reenter() external {
        // arrange
        _validateCallback = _reenterSwap;
        address lToken0;
        address lToken1;
        (lToken0, lToken1) = _getToken0Token1(address(_tokenA), address(_tokenB));

        // act
        MintableERC20(lToken0).mint(address(_stablePair), 1e18);
        vm.expectRevert("REENTRANCY");
        _stablePair.swap(1e18, true, address(this), bytes(hex"00"));
    }

    function testSwap_ZeroInput() public {
        // act & assert
        vm.expectRevert("SP: AMOUNT_ZERO");
        _stablePair.swap(0, true, address(this), "");
    }

    function testSwap_MinInt256() external {
        // arrange
        int256 lSwapAmt = type(int256).min;

        // act & assert
        vm.expectRevert(stdError.arithmeticError);
        _stablePair.swap(lSwapAmt, true, address(this), "");
    }

    function testSwap_Token0ExactOut(uint256 aAmountOut) public {
        // assume
        uint256 lAmountOut = bound(aAmountOut, 1e6, Constants.INITIAL_MINT_AMOUNT - 1);

        // arrange
        (uint104 lReserve0, uint104 lReserve1,,) = _stablePair.getReserves();
        uint256 lAmountIn = StableMath._getAmountIn(
            lAmountOut,
            lReserve0,
            lReserve1,
            1,
            1,
            true,
            Constants.DEFAULT_SWAP_FEE_SP,
            2 * _stablePair.getCurrentAPrecise()
        );

        // sanity - given a balanced pool, the amountIn should be greater than amountOut
        assertGt(lAmountIn, lAmountOut);

        // act
        _tokenB.mint(address(_stablePair), lAmountIn);
        uint256 lActualOut = _stablePair.swap(int256(lAmountOut), false, address(this), bytes(""));

        // assert
        uint256 inverse = StableMath._getAmountOut(
            lAmountIn,
            lReserve0,
            lReserve1,
            1,
            1,
            false,
            Constants.DEFAULT_SWAP_FEE_SP,
            2 * _stablePair.getCurrentAPrecise()
        );
        // todo: investigate why it has this (small) difference of around (less than 1/10 of a basis point)
        assertApproxEqRel(inverse, lActualOut, 0.00001e18);
        assertEq(lActualOut, lAmountOut);
    }

    function testSwap_Token1ExactOut(uint256 aAmountOut) public {
        // assume
        uint256 lAmountOut = bound(aAmountOut, 1e6, Constants.INITIAL_MINT_AMOUNT - 1);

        // arrange
        (uint104 lReserve0, uint104 lReserve1,,) = _stablePair.getReserves();
        uint256 lAmountIn = StableMath._getAmountIn(
            lAmountOut,
            lReserve0,
            lReserve1,
            1,
            1,
            false,
            Constants.DEFAULT_SWAP_FEE_SP,
            2 * _stablePair.getCurrentAPrecise()
        );

        // sanity - given a balanced pool, the amountIn should be greater than amountOut
        assertGt(lAmountIn, lAmountOut);

        // act
        _tokenA.mint(address(_stablePair), lAmountIn);
        uint256 lActualOut = _stablePair.swap(-int256(lAmountOut), false, address(this), bytes(""));

        // assert
        uint256 inverse = StableMath._getAmountOut(
            lAmountIn,
            lReserve0,
            lReserve1,
            1,
            1,
            true,
            Constants.DEFAULT_SWAP_FEE_SP,
            2 * _stablePair.getCurrentAPrecise()
        );
        // todo: investigate why it has this (small) difference of around (less than 1/10 of a basis point)
        assertApproxEqRel(inverse, lActualOut, 0.00001e18);
        assertEq(lActualOut, lAmountOut);
    }

    function testSwap_ExactOutExceedReserves() public {
        // act & assert
        vm.expectRevert("SP: NOT_ENOUGH_LIQ");
        _stablePair.swap(int256(Constants.INITIAL_MINT_AMOUNT), false, address(this), bytes(""));

        vm.expectRevert("SP: NOT_ENOUGH_LIQ");
        _stablePair.swap(int256(Constants.INITIAL_MINT_AMOUNT + 1), false, address(this), bytes(""));

        vm.expectRevert("SP: NOT_ENOUGH_LIQ");
        _stablePair.swap(-int256(Constants.INITIAL_MINT_AMOUNT), false, address(this), bytes(""));

        vm.expectRevert("SP: NOT_ENOUGH_LIQ");
        _stablePair.swap(-int256(Constants.INITIAL_MINT_AMOUNT + 1), false, address(this), bytes(""));
    }

    function testSwap_ExactInExceedUint104() external {
        // arrange
        uint256 lSwapAmt = type(uint104).max - Constants.INITIAL_MINT_AMOUNT + 1;

        // act & assert
        _tokenA.mint(address(_stablePair), lSwapAmt);
        vm.expectRevert("RP: OVERFLOW");
        _stablePair.swap(int256(lSwapAmt), true, address(this), "");
    }

    function testSwap_BetterPerformanceThanConstantProduct() public {
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

    function testSwap_VerySmallLiquidity(uint256 aAmtBToMint, uint256 aAmtCToMint, uint256 aSwapAmt) public {
        // assume
        uint256 lMinLiq = _stablePair.MINIMUM_LIQUIDITY();
        uint256 lAmtBToMint = bound(aAmtBToMint, lMinLiq / 2 + 1, lMinLiq);
        uint256 lAmtCToMint = bound(aAmtCToMint, lMinLiq / 2 + 1, lMinLiq);
        uint256 lSwapAmt = bound(aSwapAmt, 1, type(uint104).max - lAmtBToMint);

        // arrange
        StablePair lPair = StablePair(_createPair(address(_tokenB), address(_tokenC), 1));
        _tokenB.mint(address(lPair), lAmtBToMint);
        _tokenC.mint(address(lPair), lAmtCToMint);
        lPair.mint(address(this));

        // sanity
        assertGe(lPair.balanceOf(address(this)), 2);

        // act
        _tokenB.mint(address(lPair), lSwapAmt);
        uint256 lAmtOut =
            lPair.swap(lPair.token0() == _tokenB ? int256(lSwapAmt) : -int256(lSwapAmt), true, address(this), bytes(""));

        // assert
        uint256 lExpectedAmountOut = StableMath._getAmountOut(
            lSwapAmt,
            lPair.token0() == _tokenB ? lAmtBToMint : lAmtCToMint,
            lPair.token1() == _tokenB ? lAmtBToMint : lAmtCToMint,
            1,
            1,
            lPair.token0() == _tokenB,
            Constants.DEFAULT_SWAP_FEE_SP,
            2 * _stablePair.getCurrentAPrecise()
        );
        assertEq(lAmtOut, lExpectedAmountOut);
    }

    function testSwap_VeryLargeLiquidity(uint256 aSwapAmt) public {
        // assume
        uint256 lSwapAmt = bound(aSwapAmt, 1, 10e18);
        uint256 lAmtBToMint = type(uint104).max;
        uint256 lAmtCToMint = type(uint104).max - lSwapAmt;

        // arrange
        StablePair lPair = StablePair(_createPair(address(_tokenB), address(_tokenC), 1));
        _tokenB.mint(address(lPair), lAmtBToMint);
        _tokenC.mint(address(lPair), lAmtCToMint);
        lPair.mint(address(this));

        // act
        _tokenC.mint(address(lPair), lSwapAmt);
        uint256 lAmtOut =
            lPair.swap(lPair.token0() == _tokenC ? int256(lSwapAmt) : -int256(lSwapAmt), true, address(this), bytes(""));

        // assert
        uint256 lExpectedAmountOut = StableMath._getAmountOut(
            lSwapAmt,
            lPair.token0() == _tokenB ? lAmtBToMint : lAmtCToMint,
            lPair.token1() == _tokenB ? lAmtBToMint : lAmtCToMint,
            1,
            1,
            lPair.token0() == _tokenC,
            Constants.DEFAULT_SWAP_FEE_SP,
            2 * _stablePair.getCurrentAPrecise()
        );
        assertEq(lAmtOut, lExpectedAmountOut);
    }

    function testSwap_DiffSwapFees(uint256 aSwapFee) public {
        // assume
        uint256 lSwapFee = bound(aSwapFee, 0, _stablePair.MAX_SWAP_FEE());

        // arrange
        StablePair lPair = StablePair(_createPair(address(_tokenC), address(_tokenD), 1));
        vm.prank(address(_factory));
        lPair.setCustomSwapFee(lSwapFee);
        uint256 lTokenCMintAmt = 100_000_000e18;
        uint256 lTokenDMintAmt = 120_000_000e6;
        _tokenC.mint(address(lPair), lTokenCMintAmt);
        _tokenD.mint(address(lPair), lTokenDMintAmt);
        lPair.mint(address(this));

        uint256 lSwapAmt = 10_000_000e6;
        _tokenD.mint(address(lPair), lSwapAmt);

        // act
        uint256 lAmtOut =
            lPair.swap(lPair.token0() == _tokenD ? int256(lSwapAmt) : -int256(lSwapAmt), true, address(this), bytes(""));

        uint256 lExpectedAmtOut = StableMath._getAmountOut(
            lSwapAmt,
            lPair.token0() == _tokenD ? lTokenDMintAmt : lTokenCMintAmt,
            lPair.token1() == _tokenD ? lTokenDMintAmt : lTokenCMintAmt,
            lPair.token0() == _tokenD ? 1e12 : 1,
            lPair.token1() == _tokenD ? 1e12 : 1,
            lPair.token0() == _tokenD,
            lSwapFee,
            2 * lPair.getCurrentAPrecise()
        );

        // assert
        assertEq(lAmtOut, lExpectedAmtOut);
    }

    function testSwap_IncreasingSwapFees(uint256 aSwapFee0, uint256 aSwapFee1, uint256 aSwapFee2) public {
        // assume
        uint256 lSwapFee0 = bound(aSwapFee0, 0, _stablePair.MAX_SWAP_FEE() / 4); // between 0 - 0.5%
        uint256 lSwapFee1 = bound(aSwapFee1, _stablePair.MAX_SWAP_FEE() / 4 + 1, _stablePair.MAX_SWAP_FEE() / 2); // between
            // 0.5 - 1%
        uint256 lSwapFee2 = bound(aSwapFee2, _stablePair.MAX_SWAP_FEE() / 2 + 1, _stablePair.MAX_SWAP_FEE()); // between 1
            // - 2%

        // sanity
        assertGt(lSwapFee1, lSwapFee0);
        assertGt(lSwapFee2, lSwapFee1);

        // arrange
        uint256 lSwapAmt = 10e18;
        (uint256 lReserve0, uint256 lReserve1,,) = _stablePair.getReserves();

        // act
        vm.prank(address(_factory));
        _stablePair.setCustomSwapFee(lSwapFee0);
        uint256 lBefore = vm.snapshot();

        uint256 lExpectedOut0 = StableMath._getAmountOut(
            lSwapAmt, lReserve0, lReserve1, 1, 1, true, lSwapFee0, 2 * _stablePair.getCurrentAPrecise()
        );
        _tokenA.mint(address(_stablePair), lSwapAmt);
        uint256 lActualOut = _stablePair.swap(int256(lSwapAmt), true, address(this), bytes(""));
        assertEq(lExpectedOut0, lActualOut);

        vm.revertTo(lBefore);
        vm.prank(address(_factory));
        _stablePair.setCustomSwapFee(lSwapFee1);
        lBefore = vm.snapshot();

        uint256 lExpectedOut1 = StableMath._getAmountOut(
            lSwapAmt, lReserve0, lReserve1, 1, 1, true, lSwapFee1, 2 * _stablePair.getCurrentAPrecise()
        );
        _tokenA.mint(address(_stablePair), lSwapAmt);
        lActualOut = _stablePair.swap(int256(lSwapAmt), true, address(this), bytes(""));
        assertEq(lExpectedOut1, lActualOut);

        vm.revertTo(lBefore);
        vm.prank(address(_factory));
        _stablePair.setCustomSwapFee(lSwapFee2);

        uint256 lExpectedOut2 = StableMath._getAmountOut(
            lSwapAmt, lReserve0, lReserve1, 1, 1, true, lSwapFee2, 2 * _stablePair.getCurrentAPrecise()
        );
        _tokenA.mint(address(_stablePair), lSwapAmt);
        lActualOut = _stablePair.swap(int256(lSwapAmt), true, address(this), bytes(""));
        assertEq(lExpectedOut2, lActualOut);

        // assert
        assertLt(lExpectedOut1, lExpectedOut0);
        assertLt(lExpectedOut2, lExpectedOut1);
    }

    function testSwap_DiffAs(uint256 aAmpCoeff, uint256 aSwapAmt, uint256 aMintAmt) public {
        // assume
        uint256 lAmpCoeff = bound(aAmpCoeff, StableMath.MIN_A, StableMath.MAX_A);
        uint256 lSwapAmt = bound(aSwapAmt, 1e3, type(uint104).max / 2);
        uint256 lCMintAmt = bound(aMintAmt, 1e18, 10_000_000_000e18);
        uint256 lDMintAmt = bound(lCMintAmt, lCMintAmt / 1e12 / 1e3, lCMintAmt / 1e12 * 1e3);

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
        lPair.swap(lPair.token0() == _tokenD ? int256(lSwapAmt) : -int256(lSwapAmt), true, address(this), bytes(""));

        // assert
        uint256 lExpectedOutput = StableMath._getAmountOut(
            lSwapAmt,
            lPair.token0() == _tokenD ? lDMintAmt : lCMintAmt,
            lPair.token1() == _tokenD ? lDMintAmt : lCMintAmt,
            lPair.token0() == _tokenD ? 1e12 : 1,
            lPair.token1() == _tokenD ? 1e12 : 1,
            lPair.token0() == _tokenD,
            lPair.swapFee(),
            2 * lPair.getCurrentAPrecise()
        );
        assertEq(_tokenC.balanceOf(address(this)), lExpectedOutput);
    }

    function testBurn() public {
        // arrange
        vm.startPrank(_alice);
        uint256 lLpTokenBalance = _stablePair.balanceOf(_alice);
        uint256 lLpTokenTotalSupply = _stablePair.totalSupply();
        (uint256 lReserve0, uint256 lReserve1,,) = _stablePair.getReserves();
        ERC20 lToken0 = _stablePair.token0();

        // act
        _stablePair.transfer(address(_stablePair), _stablePair.balanceOf(_alice));
        _stablePair.burn(_alice);

        // assert
        uint256 lExpectedTokenAReceived;
        uint256 lExpectedTokenBReceived;
        if (lToken0 == _tokenA) {
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

    function testBurn_Reenter() external {
        // arrange
        vm.prank(address(_factory));
        _stablePair.setManager(_reenter);

        // act & assert
        vm.expectRevert("REENTRANCY");
        _stablePair.burn(address(this));
    }

    function testBurn_Zero() public {
        // act
        vm.expectEmit(true, true, true, true);
        emit Burn(address(this), 0, 0);
        _stablePair.burn(address(this));

        // assert
        assertEq(_tokenA.balanceOf(address(this)), 0);
        assertEq(_tokenB.balanceOf(address(this)), 0);
        assertEq(_tokenA.balanceOf(address(_stablePair)), Constants.INITIAL_MINT_AMOUNT);
        assertEq(_tokenB.balanceOf(address(_stablePair)), Constants.INITIAL_MINT_AMOUNT);
    }

    function testBurn_WhenRampingA(uint256 aFutureA) external {
        // assume - for ramping up or down from Constants.DEFAULT_AMP_COEFF
        uint64 lFutureAToSet = uint64(bound(aFutureA, 100, 5000));
        vm.assume(lFutureAToSet != Constants.DEFAULT_AMP_COEFF);
        uint64 lFutureATimestamp = uint64(block.timestamp) + 5 days;
        uint256 lBalance = _stablePair.balanceOf(_alice);

        // arrange
        vm.prank(address(_factory));
        _stablePair.rampA(lFutureAToSet, lFutureATimestamp);
        uint256 lBefore = vm.snapshot();

        // act
        vm.warp(lFutureATimestamp / 2);
        vm.prank(_alice);
        _stablePair.transfer(address(_stablePair), lBalance / 2);
        _stablePair.burn(address(this));
        uint256 lTokenABal0 = _tokenA.balanceOf(address(this));
        uint256 lTokenBBal0 = _tokenB.balanceOf(address(this));

        vm.revertTo(lBefore);

        vm.warp(lFutureATimestamp);
        vm.prank(_alice);
        _stablePair.transfer(address(_stablePair), lBalance / 2);
        _stablePair.burn(address(this));
        uint256 lTokenABal1 = _tokenA.balanceOf(address(this));
        uint256 lTokenBBal1 = _tokenB.balanceOf(address(this));

        // assert - amount received should be the same regardless of A
        assertEq(lTokenABal0, lTokenABal1);
        assertEq(lTokenBBal0, lTokenBBal1);
    }

    function testBurn_DiffDecimalPlaces(uint256 aAmtToBurn) public {
        // assume
        uint256 lAmtToBurn = bound(aAmtToBurn, 2, 2e12 - 1);

        // arrange - tokenD has 6 decimal places, simulating USDC / USDT
        StablePair lPair = StablePair(_createPair(address(_tokenC), address(_tokenD), 1));

        _tokenC.mint(address(lPair), Constants.INITIAL_MINT_AMOUNT);
        _tokenD.mint(address(lPair), Constants.INITIAL_MINT_AMOUNT / 1e12);

        lPair.mint(address(this));

        // sanity
        assertEq(lPair.balanceOf(address(this)), 2 * Constants.INITIAL_MINT_AMOUNT - lPair.MINIMUM_LIQUIDITY());

        // act
        lPair.transfer(address(lPair), lAmtToBurn);
        (uint256 lAmt0, uint256 lAmt1) = lPair.burn(address(this));

        // assert
        (uint256 lAmtC, uint256 lAmtD) = lPair.token0() == _tokenC ? (lAmt0, lAmt1) : (lAmt1, lAmt0);
        assertEq(lAmtD, 0);
        assertGt(lAmtC, 0);
    }

    function testBurn_LastInvariantUseReserveInsteadOfBalance() external {
        // arrange - trigger a write to the lastInvariant via burn
        uint256 lBalance = _stablePair.balanceOf(_alice);
        vm.prank(_alice);
        _stablePair.transfer(address(_stablePair), lBalance / 2);
        _stablePair.burn(address(this));

        // grow the liq in the pool so that there is platformFee to be minted
        uint256 lSwapAmt = 10e18;
        _tokenA.mint(address(_stablePair), lSwapAmt);
        _stablePair.swap(int256(lSwapAmt), true, address(this), "");

        // act - do a zero burn to trigger minting of platformFee
        _stablePair.burn(address(this));

        // assert
        assertEq(_stablePair.balanceOf(_platformFeeTo), 249_949_579_285_927);
    }

    function testPlatformFee_Disable() external {
        // sanity
        assertGt(_stablePair.platformFee(), 0);
        _stablePair.sync();
        ERC20 lToken0 = _stablePair.token0();
        ERC20 lToken1 = _stablePair.token1();
        uint256 lSwapAmount = Constants.INITIAL_MINT_AMOUNT / 2;
        deal(address(lToken0), address(this), lSwapAmount);

        // swap lSwapAmount back and forth
        lToken0.transfer(address(_stablePair), lSwapAmount);
        uint256 lAmountOut = _stablePair.swap(int256(lSwapAmount), true, address(this), bytes(""));
        lToken1.transfer(address(_stablePair), lAmountOut);
        lAmountOut = _stablePair.swap(-int256(lAmountOut), true, address(this), bytes(""));

        _stablePair.sync();
        assertGt(lToken0.balanceOf(address(_stablePair)), Constants.INITIAL_MINT_AMOUNT);
        assertEq(lToken1.balanceOf(address(_stablePair)), Constants.INITIAL_MINT_AMOUNT);
        assertEq(_stablePair.platformFee(), Constants.DEFAULT_PLATFORM_FEE);
        assertEq(_constantProductPair.balanceOf(address(_platformFeeTo)), 0);

        _stablePair.burn(address(this));
        uint256 lPlatformShares = _stablePair.balanceOf(address(_platformFeeTo));
        assertGt(lPlatformShares, 0);

        // arrange
        vm.prank(address(_factory));
        _stablePair.setCustomPlatformFee(0);

        // act
        lToken0.transfer(address(_stablePair), lAmountOut);
        lAmountOut = _stablePair.swap(int256(lAmountOut), true, address(this), bytes(""));
        lToken1.transfer(address(_stablePair), lAmountOut);
        _stablePair.swap(-int256(lAmountOut), true, address(this), bytes(""));

        // assert
        _stablePair.burn(address(this));
        assertEq(_stablePair.balanceOf(address(_platformFeeTo)), lPlatformShares);
    }

    function testPlatformFee_DisableReenable() external {
        // sanity
        assertGt(_stablePair.platformFee(), 0);
        _stablePair.sync();
        ERC20 lToken0 = _stablePair.token0();
        ERC20 lToken1 = _stablePair.token1();
        uint256 lSwapAmount = Constants.INITIAL_MINT_AMOUNT / 2;
        deal(address(lToken0), address(this), lSwapAmount);

        // act - swap once with platform fee.
        lToken0.transfer(address(_stablePair), lSwapAmount);
        uint256 lAmountOut = _stablePair.swap(int256(lSwapAmount), true, address(this), bytes(""));
        lToken1.transfer(address(_stablePair), lAmountOut);
        lAmountOut = _stablePair.swap(-int256(lAmountOut), true, address(this), bytes(""));

        _stablePair.sync();
        assertGt(lToken0.balanceOf(address(_stablePair)), Constants.INITIAL_MINT_AMOUNT);
        assertGe(lToken1.balanceOf(address(_stablePair)), Constants.INITIAL_MINT_AMOUNT);
        assertEq(_stablePair.platformFee(), Constants.DEFAULT_PLATFORM_FEE);
        assertEq(_constantProductPair.balanceOf(address(_platformFeeTo)), 0);

        _stablePair.burn(address(this));
        uint256 lPlatformShares = _stablePair.balanceOf(address(_platformFeeTo));
        assertGt(lPlatformShares, 0);

        // arrange
        vm.prank(address(_factory));
        _stablePair.setCustomPlatformFee(0);

        // act - swap twice with no platform fee.
        lToken0.transfer(address(_stablePair), lAmountOut);
        lAmountOut = _stablePair.swap(int256(lAmountOut), true, address(this), bytes(""));
        lToken1.transfer(address(_stablePair), lAmountOut);
        lAmountOut = _stablePair.swap(-int256(lAmountOut), true, address(this), bytes(""));
        lToken0.transfer(address(_stablePair), lAmountOut);
        lAmountOut = _stablePair.swap(int256(lAmountOut), true, address(this), bytes(""));
        lToken1.transfer(address(_stablePair), lAmountOut);
        lAmountOut = _stablePair.swap(-int256(lAmountOut), true, address(this), bytes(""));

        // assert
        _stablePair.burn(address(this));
        assertEq(_stablePair.balanceOf(address(_platformFeeTo)), lPlatformShares);

        // act - swap once at half volume, again with platform fee.
        vm.prank(address(_factory));
        _stablePair.setCustomPlatformFee(type(uint256).max);
        _stablePair.burn(address(this));
        lToken0.transfer(address(_stablePair), lAmountOut / 2);
        lAmountOut = _stablePair.swap(int256(lAmountOut / 2), true, address(this), bytes(""));
        lToken1.transfer(address(_stablePair), lAmountOut);
        lAmountOut = _stablePair.swap(-int256(lAmountOut), true, address(this), bytes(""));

        // assert - we shouldn't have received more than the first time because
        //          we disabled fees for the high volume.
        _stablePair.burn(address(this));
        uint256 lNewShares = _stablePair.balanceOf(address(_platformFeeTo)) - lPlatformShares;
        assertLt(lNewShares, lPlatformShares);
    }

    function testRampA() public {
        // arrange
        uint64 lCurrentTimestamp = uint64(block.timestamp);
        uint64 lFutureATimestamp = lCurrentTimestamp + 3 days;
        uint64 lFutureAToSet = 5000;

        // act
        vm.expectEmit(true, true, true, true);
        emit RampA(
            uint64(Constants.DEFAULT_AMP_COEFF) * uint64(StableMath.A_PRECISION),
            lFutureAToSet * uint64(StableMath.A_PRECISION),
            lCurrentTimestamp,
            lFutureATimestamp
        );
        _factory.rawCall(
            address(_stablePair), abi.encodeWithSignature("rampA(uint64,uint64)", lFutureAToSet, lFutureATimestamp), 0
        );

        // assert
        (uint64 lInitialA, uint64 lFutureA, uint64 lInitialATime, uint64 lFutureATime) = _stablePair.ampData();
        assertEq(lInitialA, Constants.DEFAULT_AMP_COEFF * uint64(StableMath.A_PRECISION));
        assertEq(_stablePair.getCurrentA(), Constants.DEFAULT_AMP_COEFF);
        assertEq(lFutureA, lFutureAToSet * uint64(StableMath.A_PRECISION));
        assertEq(lInitialATime, block.timestamp);
        assertEq(lFutureATime, lFutureATimestamp);
    }

    function testRampA_OnlyFactory() public {
        // act && assert
        vm.expectRevert("RP: FORBIDDEN");
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

    function testRampA_MaxSpeed_Double() public {
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

    function testRampA_MaxSpeed_Halve() public {
        // arrange
        uint64 lCurrentTimestamp = uint64(block.timestamp);
        uint64 lFutureATimestamp = lCurrentTimestamp + 1 days;
        uint64 lFutureAToSet = _stablePair.getCurrentA() / 2;

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

    function testRampA_BreachMaxSpeed_Halve() public {
        // arrange
        uint64 lCurrentTimestamp = uint64(block.timestamp);
        uint64 lFutureATimestamp = lCurrentTimestamp + 1 days;
        uint64 lFutureAToSet = _stablePair.getCurrentA() / 2 - 1;

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
        vm.expectRevert("RP: FORBIDDEN");
        _stablePair.stopRampA();
    }

    function testStopRampA_Early(uint256 aFutureA) public {
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
        uint256 lTotalADiff = lFutureAToSet > lInitialA ? lFutureAToSet - lInitialA : lInitialA - lFutureAToSet;
        uint256 lActualADiff =
            lFutureAToSet > lInitialA ? _stablePair.getCurrentA() - lInitialA : lInitialA - _stablePair.getCurrentA();
        assertApproxEqAbs(lActualADiff, lTotalADiff / 2, 1);
        (uint64 lNewInitialA, uint64 lNewFutureA, uint64 lInitialATime, uint64 lFutureATime) = _stablePair.ampData();
        assertEq(lNewInitialA, lNewFutureA);
        assertEq(lInitialATime, block.timestamp);
        assertEq(lFutureATime, block.timestamp);
    }

    function testStopRampA_Late(uint256 aFutureA) public {
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
        assertEq(_stablePair.getCurrentA(), Constants.DEFAULT_AMP_COEFF);

        // warp to the midpoint between the initialATime and futureATime
        vm.warp((lFutureATimestamp + block.timestamp) / 2);
        assertEq(_stablePair.getCurrentA(), (Constants.DEFAULT_AMP_COEFF + lFutureAToSet) / 2);

        // warp to the end
        vm.warp(lFutureATimestamp);
        assertEq(_stablePair.getCurrentA(), lFutureAToSet);
    }

    function testRampA_SwappingDuringRampingUp(uint256 aSeed, uint256 aFutureA, uint256 aDuration, uint256 aSwapAmount)
        public
    {
        // assume
        uint64 lFutureAToSet = uint64(bound(aFutureA, _stablePair.getCurrentA(), StableMath.MAX_A));
        uint256 lMinRampDuration = lFutureAToSet / _stablePair.getCurrentA() * 1 days;
        uint256 lMaxRampDuration = 30 days; // 1 month
        uint64 lCurrentTimestamp = uint64(block.timestamp);
        uint64 lFutureATimestamp = lCurrentTimestamp + uint64(bound(aDuration, lMinRampDuration, lMaxRampDuration));
        int256 lAmountToSwap = int256(bound(aSwapAmount, 1, type(uint104).max / 2));

        // arrange
        uint64 lRemainingTime = lFutureATimestamp - lCurrentTimestamp;

        // act
        _factory.rawCall(
            address(_stablePair), abi.encodeWithSignature("rampA(uint64,uint64)", lFutureAToSet, lFutureATimestamp), 0
        );

        uint256 lBefore = vm.snapshot();
        _tokenA.mint(address(_stablePair), uint256(lAmountToSwap));
        uint256 lAmountOutBeforeRamp = _stablePair.swap(lAmountToSwap, true, address(this), "");

        vm.revertTo(lBefore);
        lBefore = vm.snapshot();

        uint256 lTimeToSkip = bound(aSeed, 0, lRemainingTime / 4);
        _stepTime(lTimeToSkip);
        _tokenA.mint(address(_stablePair), uint256(lAmountToSwap));
        uint256 lAmountOutT1 = _stablePair.swap(lAmountToSwap, true, address(this), "");

        vm.revertTo(lBefore);
        lBefore = vm.snapshot();

        lTimeToSkip = bound(aSeed, lRemainingTime / 4, lRemainingTime / 2);
        _stepTime(lTimeToSkip);
        _tokenA.mint(address(_stablePair), uint256(lAmountToSwap));
        uint256 lAmountOutT2 = _stablePair.swap(lAmountToSwap, true, address(this), "");

        vm.revertTo(lBefore);

        _stepTime(lRemainingTime);
        _tokenA.mint(address(_stablePair), uint256(lAmountToSwap));
        uint256 lAmountOutT3 = _stablePair.swap(lAmountToSwap, true, address(this), "");

        // assert - output amount over time should be increasing or be within 1 due to rounding error
        assertTrue(lAmountOutT1 >= lAmountOutBeforeRamp || MathUtils.within1(lAmountOutT1, lAmountOutBeforeRamp));
        assertTrue(lAmountOutT2 >= lAmountOutT1 || MathUtils.within1(lAmountOutT2, lAmountOutT1));
        assertTrue(lAmountOutT3 >= lAmountOutT2 || MathUtils.within1(lAmountOutT3, lAmountOutT2));
    }

    function testRampA_SwappingDuringRampingDown(
        uint256 aSeed,
        uint256 aFutureA,
        uint256 aDuration,
        uint256 aSwapAmount
    ) public {
        // assume
        uint64 lFutureAToSet = uint64(bound(aFutureA, StableMath.MIN_A, _stablePair.getCurrentA()));
        uint256 lMinRampDuration = _stablePair.getCurrentA() / lFutureAToSet * 1 days;
        uint256 lMaxRampDuration = 1000 days;
        uint64 lCurrentTimestamp = uint64(block.timestamp);
        uint64 lFutureATimestamp = lCurrentTimestamp + uint64(bound(aDuration, lMinRampDuration, lMaxRampDuration));
        int256 lAmountToSwap = int256(bound(aSwapAmount, 1, type(uint104).max / 2));

        // arrange
        uint64 lRemainingTime = lFutureATimestamp - lCurrentTimestamp;

        // act
        _factory.rawCall(
            address(_stablePair), abi.encodeWithSignature("rampA(uint64,uint64)", lFutureAToSet, lFutureATimestamp), 0
        );

        uint256 lBefore = vm.snapshot();
        _tokenA.mint(address(_stablePair), uint256(lAmountToSwap));
        uint256 lAmountOutBeforeRamp = _stablePair.swap(lAmountToSwap, true, address(this), "");

        vm.revertTo(lBefore);
        lBefore = vm.snapshot();

        uint256 lTimeToSkip = bound(aSeed, 0, lRemainingTime / 4);
        _stepTime(lTimeToSkip);
        _tokenA.mint(address(_stablePair), uint256(lAmountToSwap));
        uint256 lAmountOutT1 = _stablePair.swap(lAmountToSwap, true, address(this), "");

        vm.revertTo(lBefore);
        lBefore = vm.snapshot();

        lTimeToSkip = bound(aSeed, lRemainingTime / 4, lRemainingTime / 2);
        _stepTime(lTimeToSkip);
        _tokenA.mint(address(_stablePair), uint256(lAmountToSwap));
        uint256 lAmountOutT2 = _stablePair.swap(lAmountToSwap, true, address(this), "");

        vm.revertTo(lBefore);

        _stepTime(lRemainingTime);
        _tokenA.mint(address(_stablePair), uint256(lAmountToSwap));
        uint256 lAmountOutT3 = _stablePair.swap(lAmountToSwap, true, address(this), "");

        // assert - output amount over time should be decreasing or within 1 due to rounding error
        assertTrue(lAmountOutT1 <= lAmountOutBeforeRamp || MathUtils.within1(lAmountOutT1, lAmountOutBeforeRamp));
        assertTrue(lAmountOutT2 <= lAmountOutT1 || MathUtils.within1(lAmountOutT2, lAmountOutT1));
        assertTrue(lAmountOutT3 <= lAmountOutT2 || MathUtils.within1(lAmountOutT3, lAmountOutT2));
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
        uint256 lSwapAmt = 70e18;
        _tokenA.mint(address(_stablePair), lSwapAmt);
        uint256 lAmtOut = _stablePair.swap(int256(lSwapAmt), true, address(this), bytes(""));

        assertEq(lAmtOut, 69_897_580_651_885_320_277);
        assertEq(_tokenB.balanceOf(address(this)), 69_897_580_651_885_320_277);

        // Pool is imbalanced! Now trades from tokenB -> tokenA may be profitable in small sizes
        // tokenA balance in the pool  : 170e18
        // tokenB balance in the pool : 30.10e18
        (uint104 lReserve0, uint104 lReserve1,,) = _stablePair.getReserves();
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
        (lReserve0, lReserve1,,) = _stablePair.getReserves();
        assertGt(lReserve0, Constants.INITIAL_MINT_AMOUNT);
        assertEq(lReserve1, Constants.INITIAL_MINT_AMOUNT);
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
        uint256 lSwapAmt = 70e18;
        _tokenA.mint(address(_stablePair), lSwapAmt);
        uint256 lAmtOut = _stablePair.swap(int256(lSwapAmt), true, address(this), bytes(""));

        assertEq(lAmtOut, 69_897_580_651_885_320_277);
        assertEq(_tokenB.balanceOf(address(this)), 69_897_580_651_885_320_277);

        // Pool is imbalanced! Now trades from tokenB -> tokenA may be profitable in small sizes
        // tokenA balance in the pool  : 170e18
        // tokenB balance in the pool : 30.10e18
        (uint104 lReserve0, uint104 lReserve1,,) = _stablePair.getReserves();
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
        (lReserve0, lReserve1,,) = _stablePair.getReserves();
        assertEq(lReserve0, 99_871_702_539_906_228_887);
        assertEq(lReserve1, Constants.INITIAL_MINT_AMOUNT);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    ORACLE
    //////////////////////////////////////////////////////////////////////////*/

    function testOracle_NoWriteInSameTimestamp() public {
        // arrange
        (,,, uint16 lInitialIndex) = _constantProductPair.getReserves();
        uint256 lAmountToSwap = 1e17;

        // act
        _tokenA.mint(address(_stablePair), lAmountToSwap);
        _stablePair.swap(int256(lAmountToSwap), true, address(this), "");

        vm.prank(_alice);
        _stablePair.transfer(address(_stablePair), 1e18);
        _stablePair.burn(address(this));

        _stablePair.sync();

        // assert
        (,,, uint16 lFinalIndex) = _constantProductPair.getReserves();
        assertEq(lFinalIndex, lInitialIndex);
    }

    function testOracle_WrapsAroundAfterFull() public {
        // arrange
        uint256 lAmountToSwap = 1e15;
        uint256 lMaxObservations = 2 ** 16;

        // act
        for (uint256 i = 0; i < lMaxObservations + 4; ++i) {
            _stepTime(5);
            _tokenA.mint(address(_stablePair), lAmountToSwap);
            _stablePair.swap(int256(lAmountToSwap), true, address(this), "");
        }

        // assert
        (,,, uint16 lIndex) = _stablePair.getReserves();
        assertEq(lIndex, 3);
    }

    function testWriteObservations() external {
        // arrange
        // swap 1
        _stepTime(1);
        (uint256 lReserve0, uint256 lReserve1,,) = _stablePair.getReserves();
        _tokenA.mint(address(_stablePair), 5e18);
        _stablePair.swap(5e18, true, address(this), "");

        // swap 2
        _stepTime(1);
        (lReserve0, lReserve1,,) = _stablePair.getReserves();
        _tokenA.mint(address(_stablePair), 5e18);
        _stablePair.swap(5e18, true, address(this), "");

        // sanity
        (,,, uint16 lIndex) = _stablePair.getReserves();
        assertEq(lIndex, 1);

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
        (,,, uint16 lIndex) = _stablePair.getReserves();
        _writeObservation(_stablePair, lIndex, type(int112).max, type(int56).max, 0, uint32(block.timestamp));
        Observation memory lPrevObs = _oracleCaller.observation(_stablePair, lIndex);

        // act
        uint256 lAmountToSwap = 5e18;
        _tokenB.mint(address(_stablePair), lAmountToSwap);
        _stablePair.swap(-int256(lAmountToSwap), true, address(this), "");

        _stepTime(5);
        _stablePair.sync();

        // assert - when it overflows it goes from a very positive number to a very negative number
        (,,, lIndex) = _stablePair.getReserves();
        Observation memory lCurrObs = _oracleCaller.observation(_stablePair, lIndex);
        assertLt(lCurrObs.logAccRawPrice, lPrevObs.logAccRawPrice);
    }

    function testOracle_OverflowAccLiquidity() public {
        // arrange
        (,,, uint16 lIndex) = _stablePair.getReserves();
        _writeObservation(_stablePair, lIndex, 0, 0, type(int56).max, uint32(block.timestamp));
        Observation memory lPrevObs = _oracleCaller.observation(_stablePair, lIndex);

        // act
        _stepTime(5);
        _stablePair.sync();

        // assert
        (,,, lIndex) = _stablePair.getReserves();
        Observation memory lCurrObs = _oracleCaller.observation(_stablePair, lIndex);
        assertLt(lCurrObs.logAccLiquidity, lPrevObs.logAccLiquidity);
    }

    function testOracle_CorrectPrice() public {
        // arrange
        uint256 lAmountToSwap = 1e18;
        _stepTime(5);

        // act
        _tokenA.mint(address(_stablePair), lAmountToSwap);
        _stablePair.swap(int256(lAmountToSwap), true, address(this), "");

        (uint256 lReserve0_1, uint256 lReserve1_1,,) = _stablePair.getReserves();
        uint256 lPrice1 = StableOracleMath.calcSpotPrice(_stablePair.getCurrentAPrecise(), lReserve0_1, lReserve1_1);
        _stepTime(5);

        _tokenA.mint(address(_stablePair), lAmountToSwap);
        _stablePair.swap(int256(lAmountToSwap), true, address(this), "");
        (uint256 lReserve0_2, uint256 lReserve1_2,,) = _stablePair.getReserves();
        uint256 lPrice2 = StableOracleMath.calcSpotPrice(_stablePair.getCurrentAPrecise(), lReserve0_2, lReserve1_2);

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
        (uint256 lReserve0_1, uint256 lReserve1_1,,) = _stablePair.getReserves();
        uint256 lSpotPrice1 = StableOracleMath.calcSpotPrice(_stablePair.getCurrentAPrecise(), lReserve0_1, lReserve1_1);
        _stepTime(10);

        // price = 0.0000936563
        _tokenA.mint(address(_stablePair), 200e18);
        _stablePair.swap(200e18, true, _bob, "");
        (uint256 lReserve0_2, uint256 lReserve1_2,,) = _stablePair.getReserves();
        uint256 lSpotPrice2 = StableOracleMath.calcSpotPrice(_stablePair.getCurrentAPrecise(), lReserve0_2, lReserve1_2);
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
        uint256 lAmountToBurn = 1e18;

        // act
        _stepTime(5);
        vm.prank(_alice);
        _stablePair.transfer(address(_stablePair), lAmountToBurn);
        _stablePair.burn(address(this));

        // assert
        (,,, uint16 lIndex) = _stablePair.getReserves();
        Observation memory lObs0 = _oracleCaller.observation(_stablePair, lIndex);
        uint256 lAverageLiq = LogCompression.fromLowResLog(lObs0.logAccLiquidity / 5);
        // we check that it is within 0.01% of accuracy
        // sqrt(Constants.INITIAL_MINT_AMOUNT * Constants.INITIAL_MINT_AMOUNT) == Constants.INITIAL_MINT_AMOUNT
        assertApproxEqRel(lAverageLiq, Constants.INITIAL_MINT_AMOUNT, 0.0001e18);

        // act
        _stepTime(5);
        _stablePair.sync();

        // assert
        (,,, lIndex) = _stablePair.getReserves();
        Observation memory lObs1 = _oracleCaller.observation(_stablePair, lIndex);
        uint256 lAverageLiq2 = LogCompression.fromLowResLog((lObs1.logAccLiquidity - lObs0.logAccLiquidity) / 5);
        assertApproxEqRel(lAverageLiq2, Constants.INITIAL_MINT_AMOUNT - lAmountToBurn / 2, 0.0001e18);
    }

    function testOracle_LiquidityAtMaximum() external {
        // arrange
        uint256 lLiquidityToAdd = type(uint104).max - Constants.INITIAL_MINT_AMOUNT;
        _stepTime(5);
        _tokenA.mint(address(_stablePair), lLiquidityToAdd);
        _tokenB.mint(address(_stablePair), lLiquidityToAdd);
        _stablePair.mint(address(this));

        // sanity
        (uint104 lReserve0, uint104 lReserve1,,) = _stablePair.getReserves();
        assertEq(lReserve0, type(uint104).max);
        assertEq(lReserve1, type(uint104).max);

        // act
        _stepTime(5);
        _stablePair.sync();

        // assert
        uint256 lTotalSupply = _stablePair.totalSupply();
        assertEq(lTotalSupply, uint256(type(uint104).max) * 2);

        (,,, uint16 lIndex) = _stablePair.getReserves();
        Observation memory lObs0 = _oracleCaller.observation(_stablePair, 0);
        Observation memory lObs1 = _oracleCaller.observation(_stablePair, lIndex);
        assertApproxEqRel(
            type(uint104).max,
            LogCompression.fromLowResLog((lObs1.logAccLiquidity - lObs0.logAccLiquidity) / 5),
            0.0001e18
        );
    }

    function testOracle_ClampedPrice_NoDiffWithinLimit() external {
        // arrange
        _stepTime(5);
        uint256 lSwapAmt = 57e18;
        _tokenB.mint(address(_stablePair), lSwapAmt);
        _stablePair.swap(-int256(lSwapAmt), true, address(this), bytes(""));

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
