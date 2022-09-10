pragma solidity 0.8.13;

import "test/__fixtures/BaseTest.sol";

import "test/__fixtures/MintableERC20.sol";

import { MathUtils } from "src/libraries/MathUtils.sol";
import { StableMath } from "src/libraries/StableMath.sol";
import { StablePair, AmplificationData } from "src/curve/stable/StablePair.sol";
import { ConstantProductPair } from "src/curve/constant-product/ConstantProductPair.sol";
import { GenericFactory } from "src/GenericFactory.sol";
import { IAssetManager } from "src/interfaces/IAssetManager.sol";
import { AssetManager } from "test/__mocks/AssetManager.sol";

contract StablePairTest is BaseTest
{
    AssetManager private _manager = new AssetManager();

    event RampA(uint64 initialA, uint64 futureA, uint64 initialTime, uint64 futureTme);

    function _calculateConstantProductOutput(
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

    function testSwap() public
    {
        // act
        _tokenA.mint(address(address(_stablePair)), 5e18);
        uint256 lAmountOut = _stablePair.swap(address(_tokenA), address(this));

        // assert
        assertEq(lAmountOut, _tokenB.balanceOf(address(this)));
    }

    function testSwap_ZeroInput() public
    {
        // act & assert
        vm.expectRevert("SP: TRANSFER_FAILED");
        _stablePair.swap(address(_tokenA), address(this));
    }

    function testSwap_BetterPerformanceThanConstantProduct() public
    {
        // act
        uint256 lSwapAmount = 5e18;
        _tokenA.mint(address(_stablePair), lSwapAmount);
        _stablePair.swap(address(_tokenA), address(this));
        uint256 lStablePairOutput = _tokenB.balanceOf(address(this));

        uint256 lExpectedConstantProductOutput = _calculateConstantProductOutput(INITIAL_MINT_AMOUNT, INITIAL_MINT_AMOUNT, lSwapAmount, 25);
        _tokenA.mint(address(_constantProductPair), lSwapAmount);
        _constantProductPair.swap(lExpectedConstantProductOutput, 0, address(this), "");
        uint256 lConstantProductOutput = _tokenB.balanceOf(address(this)) - lStablePairOutput;

        // assert
        assertGt(lStablePairOutput, lConstantProductOutput);
    }

    function testBurn() public
    {
        // arrange
        vm.startPrank(_alice);
        uint256 lLpTokenBalance = _stablePair.balanceOf(_alice);
        uint256 lLpTokenTotalSupply = _stablePair.totalSupply();
        (uint256 lReserve0, uint256 lReserve1, ) = _stablePair.getReserves();
        address[] memory lAssets = _stablePair.getAssets();
        address lToken0 = lAssets[0];

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

    function testRecoverToken() public
    {
        // arrange
        uint256 lAmountToRecover = 1e18;
        _tokenC.mint(address(_stablePair), 1e18);

        // act
        _stablePair.recoverToken(address(_tokenC));

        // assert
        assertEq(_tokenC.balanceOf(address(_recoverer)), lAmountToRecover);
        assertEq(_tokenC.balanceOf(address(_stablePair)), 0);
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

    // todo: testStopRampA_Early
    // todo: testStopRampA_Late

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

    /*//////////////////////////////////////////////////////////////////////////
                                ASSET MANAGEMENT
    //////////////////////////////////////////////////////////////////////////*/

    function testSetManager() external
    {
        // sanity
        assertEq(address(_stablePair.assetManager()), address(0));

        // act
        vm.prank(address(_factory));
        _stablePair.setManager(_manager);

        // assert
        assertEq(address(_stablePair.assetManager()), address(_manager));
    }

    function testSetManager_CannotMigrateWithManaged() external
    {
        // arrange
        vm.prank(address(_factory));
        _stablePair.setManager(_manager);

        _manager.adjustManagement(_stablePair, 10e18, 10e18);

        // act & assert
        vm.prank(address(_factory));
        vm.expectRevert("CP: AM_STILL_ACTIVE");
        _stablePair.setManager(IAssetManager(address(0)));
    }

    function testManageReserves() external
    {
        // arrange
        _tokenA.mint(address(_stablePair), 50e18);
        _tokenB.mint(address(_stablePair), 50e18);
        _stablePair.mint(address(this));

        vm.prank(address(_factory));
        _stablePair.setManager(IAssetManager(address(this)));

        // act
        _stablePair.adjustManagement(20e18, 20e18);

        // assert
        assertEq(_tokenA.balanceOf(address(this)), 20e18);
        assertEq(_tokenB.balanceOf(address(this)), 20e18);
    }

    function testManageReserves_DecreaseManagement() external
    {
        // arrange
        vm.prank(address(_factory));
        _stablePair.setManager(_manager);

        address lToken0 = _stablePair.token0();
        address lToken1 = _stablePair.token1();

        // sanity
        (uint112 lReserve0, uint112 lReserve1, ) = _stablePair.getReserves();
        uint256 lBal0Before = IERC20(lToken0).balanceOf(address(_stablePair));
        uint256 lBal1Before = IERC20(lToken1).balanceOf(address(_stablePair));

        _manager.adjustManagement(_stablePair, 20e18, 20e18);

        //solhint-disable-next-line var-name-mixedcase
        (uint112 lReserve0_1, uint112 lReserve1_1, ) = _stablePair.getReserves();
        uint256 lBal0After = IERC20(lToken0).balanceOf(address(_stablePair));
        uint256 lBal1After = IERC20(lToken1).balanceOf(address(_stablePair));

        assertEq(uint256(lReserve0_1), lReserve0);
        assertEq(uint256(lReserve1_1), lReserve1);
        assertEq(lBal0Before - lBal0After, 20e18);
        assertEq(lBal1Before - lBal1After, 20e18);

        assertEq(IERC20(lToken0).balanceOf(address(_manager)), 20e18);
        assertEq(IERC20(lToken1).balanceOf(address(_manager)), 20e18);
        assertEq(_manager.getBalance(_stablePair, address(lToken0)), 20e18);
        assertEq(_manager.getBalance(_stablePair, address(lToken1)), 20e18);

        // act
        _manager.adjustManagement(_stablePair, -10e18, -10e18);

        //solhint-disable-next-line var-name-mixedcase
        (uint112 lReserve0_2, uint112 lReserve1_2, ) = _stablePair.getReserves();

        // assert
        assertEq(uint256(lReserve0_2), lReserve0);
        assertEq(uint256(lReserve1_2), lReserve1);
        assertEq(IERC20(lToken0).balanceOf(address(_manager)), 10e18);
        assertEq(IERC20(lToken1).balanceOf(address(_manager)), 10e18);
        assertEq(_manager.getBalance(_stablePair, address(lToken0)), 10e18);
        assertEq(_manager.getBalance(_stablePair, address(lToken1)), 10e18);
    }

    function testSyncManaged() external
    {
        // arrange
        vm.prank(address(_factory));
        _stablePair.setManager(_manager);

        address lToken0 = _stablePair.token0();
        address lToken1 = _stablePair.token1();

        _manager.adjustManagement(_stablePair, 20e18, 20e18);
        _tokenA.mint(address(_stablePair), 10e18);
        _tokenB.mint(address(_stablePair), 10e18);
        uint256 lLiq = _stablePair.mint(address(this));

        // sanity
        assertEq(lLiq, 20e18); // 10e18 + 10e18
        assertEq(_tokenA.balanceOf(address(this)), 0);
        assertEq(_tokenB.balanceOf(address(this)), 0);
        assertEq(_manager.getBalance(_stablePair, lToken0), 20e18);
        assertEq(_manager.getBalance(_stablePair, lToken1), 20e18);

        // act
        _manager.adjustBalance(_stablePair, lToken0, 19e18); // 1e18 lost
        _manager.adjustBalance(_stablePair, lToken1, 19e18); // 1e18 lost
        _stablePair.transfer(address(_stablePair), 10e18);
        _stablePair.burn(address(this));

        // assert
        assertEq(_manager.getBalance(_stablePair, lToken0), 19e18);
        assertEq(_manager.getBalance(_stablePair, lToken1), 19e18);
        assertLt(_tokenA.balanceOf(address(this)), 10e18);
        assertLt(_tokenB.balanceOf(address(this)), 10e18);
    }
}
