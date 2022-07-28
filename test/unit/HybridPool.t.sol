pragma solidity 0.8.13;

import "test/__fixtures/BaseTest.sol";

import "test/__fixtures/MintableERC20.sol";

import { MathUtils } from "src/libraries/MathUtils.sol";
import { StableMath } from "src/libraries/StableMath.sol";
import { HybridPool, AmplificationData } from "src/curve/stable/HybridPool.sol";
import { UniswapV2Pair } from "src/curve/constant-product/UniswapV2Pair.sol";
import { GenericFactory } from "src/GenericFactory.sol";

contract HybridPoolTest is BaseTest
{
    event RampA(uint64 initialA, uint64 futureA, uint64 initialTime, uint64 futureTme);

    function setUp() public
    {}

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
        uint256 lLpTokenTotalSupply = _hybridPool.totalSupply();
        (uint256 lReserve0, uint256 lReserve1) = _hybridPool.getReserves();
        uint256 lOldLiquidity = lReserve0 + lReserve1;
        uint256 lLiquidityToAdd = 5e18;

        // act
        _tokenA.mint(address(_hybridPool), lLiquidityToAdd);
        _tokenB.mint(address(_hybridPool), lLiquidityToAdd);
        _hybridPool.mint(address(this));

        // assert
        // this works only because the pools are balanced. When the pool is imbalanced the calculation will differ
        uint256 lAdditionalLpTokens = ((INITIAL_MINT_AMOUNT + lLiquidityToAdd) * 2 - lOldLiquidity) * lLpTokenTotalSupply / lOldLiquidity;
        assertEq(_hybridPool.balanceOf(address(this)), lAdditionalLpTokens);
    }

    function testMint_OnlyTransferOneToken() public
    {
        // arrange
        HybridPool lPair = HybridPool(_createPair(address(_tokenA), address(_tokenC), 1));
        _tokenA.mint(address(lPair), 5e18);

        // act & assert
        vm.expectRevert(stdError.divisionError);
        lPair.mint(address(this));
    }

    function testMintFee_CallableBySelf() public
    {
        // arrange
        vm.prank(address(_hybridPool));

        // act
        (uint256 lTotalSupply, ) = _hybridPool.mintFee(0, 0);

        // assert
        assertEq(lTotalSupply, _hybridPool.totalSupply());
    }

    function testMintFee_NotCallableByOthers() public
    {
        // act & assert
        vm.expectRevert("not self");
        _hybridPool.mintFee(0, 0);
    }

    function testSwap() public
    {
        // act
        _tokenA.mint(address(address(_hybridPool)), 5e18);
        uint256 lAmountOut = _hybridPool.swap(address(_tokenA), address(this));

        // assert
        assertEq(lAmountOut, _tokenB.balanceOf(address(this)));
    }

    function testSwap_ZeroInput() public
    {
        // act & assert
        vm.expectRevert("UniswapV2: TRANSFER_FAILED");
        _hybridPool.swap(address(_tokenA), address(this));
    }

    function testSwap_BetterPerformanceThanConstantProduct() public
    {
        // arrange
        GenericFactory lFactory = new GenericFactory();
        lFactory.addCurve(type(UniswapV2Pair).creationCode);
        lFactory.set(keccak256("UniswapV2Pair::swapFee"), bytes32(uint256(25)));
        lFactory.set(keccak256("UniswapV2Pair::platformFee"), bytes32(uint256(2500)));

        UniswapV2Pair lPair = UniswapV2Pair(lFactory.createPair(address(_tokenA), address(_tokenB), 0));
        _tokenA.mint(address(lPair), INITIAL_MINT_AMOUNT);
        _tokenB.mint(address(lPair), INITIAL_MINT_AMOUNT);
        lPair.mint(_alice);

        // act
        uint256 lSwapAmount = 5e18;
        _tokenA.mint(address(_hybridPool), lSwapAmount);
        _hybridPool.swap(address(_tokenA), address(this));
        uint256 lHybridPoolOutput = _tokenB.balanceOf(address(this));

        uint256 lExpectedConstantProductOutput = _calculateConstantProductOutput(INITIAL_MINT_AMOUNT, INITIAL_MINT_AMOUNT, lSwapAmount, 25);
        _tokenA.mint(address(lPair), lSwapAmount);
        lPair.swap(lExpectedConstantProductOutput, 0, address(this), "");
        uint256 lConstantProductOutput = _tokenB.balanceOf(address(this)) - lHybridPoolOutput;

        // assert
        assertGt(lHybridPoolOutput, lConstantProductOutput);
    }

    function testBurn() public
    {
        // arrange
        vm.startPrank(_alice);
        uint256 lLpTokenBalance = _hybridPool.balanceOf(_alice);
        uint256 lLpTokenTotalSupply = _hybridPool.totalSupply();
        (uint256 lReserve0, uint256 lReserve1) = _hybridPool.getReserves();
        address[] memory lAssets = _hybridPool.getAssets();
        address lToken0 = lAssets[0];

        // act
        _hybridPool.transfer(address(_hybridPool), _hybridPool.balanceOf(_alice));
        _hybridPool.burn(_alice);

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

        assertEq(_hybridPool.balanceOf(_alice), 0);
        assertGt(lExpectedTokenAReceived, 0);
        assertEq(_tokenA.balanceOf(_alice), lExpectedTokenAReceived);
        assertEq(_tokenB.balanceOf(_alice), lExpectedTokenBReceived);
    }

    function testRecoverToken() public
    {
        // arrange
        uint256 lAmountToRecover = 1e18;
        _tokenC.mint(address(_hybridPool), 1e18);

        // act
        _hybridPool.recoverToken(address(_tokenC));

        // assert
        assertEq(_tokenC.balanceOf(address(_recoverer)), lAmountToRecover);
        assertEq(_tokenC.balanceOf(address(_hybridPool)), 0);
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
            address(_hybridPool),
            abi.encodeWithSignature("rampA(uint64,uint64)", lFutureAToSet, lFutureATimestamp),
            0
        );

        // assert
        (uint64 lInitialA, uint64 lFutureA, uint64 lInitialATime, uint64 lFutureATime) = _hybridPool.ampData();
        assertEq(lInitialA, 1000 * uint64(StableMath.A_PRECISION));
        assertEq(_hybridPool.getCurrentA(), 1000);
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
            address(_hybridPool),
            abi.encodeWithSignature("rampA(uint64,uint64)", lFutureAToSet, lFutureATimestamp),
            0
        );

        // assert
        (, uint64 lFutureA, , ) = _hybridPool.ampData();
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
            address(_hybridPool),
            abi.encodeWithSignature("rampA(uint64,uint64)", lFutureAToSet, lFutureATimestamp),
            0
        );

        // assert
        (, uint64 lFutureA, , ) = _hybridPool.ampData();
        assertEq(lFutureA / StableMath.A_PRECISION, lFutureAToSet);
    }


    function testRampA_BreachMinimum() public
    {
        // arrange
        uint64 lCurrentTimestamp = uint64(block.timestamp);
        uint64 lFutureATimestamp = lCurrentTimestamp + 3 days;
        uint64 lFutureAToSet = uint64(StableMath.MIN_A) - 1;

        // act & assert
        vm.expectRevert("UniswapV2: INVALID A");
        _factory.rawCall(
            address(_hybridPool),
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
        vm.expectRevert("UniswapV2: INVALID A");
        _factory.rawCall(
            address(_hybridPool),
            abi.encodeWithSignature("rampA(uint64,uint64)", lFutureAToSet, lFutureATimestamp),
            0
        );
    }

    function testRampA_MaxSpeed() public
    {
        // arrange
        uint64 lCurrentTimestamp = uint64(block.timestamp);
        uint64 lFutureATimestamp = lCurrentTimestamp + 1 days;
        uint64 lFutureAToSet = _hybridPool.getCurrentA() * 2;

        // act
        _factory.rawCall(
            address(_hybridPool),
            abi.encodeWithSignature("rampA(uint64,uint64)", lFutureAToSet, lFutureATimestamp),
            0
        );

        // assert
        (, uint64 lFutureA, , ) = _hybridPool.ampData();
        assertEq(lFutureA, lFutureAToSet * StableMath.A_PRECISION);
    }

    function testRampA_BreachMaxSpeed() public
    {
        // arrange
        uint64 lCurrentTimestamp = uint64(block.timestamp);
        uint64 lFutureATimestamp = lCurrentTimestamp + 2 days - 1;
        uint64 lFutureAToSet = _hybridPool.getCurrentA() * 4;

        // act & assert
        vm.expectRevert("UniswapV2: AMP RATE TOO HIGH");
        _factory.rawCall(
            address(_hybridPool),
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
            address(_hybridPool),
            abi.encodeWithSignature("rampA(uint64,uint64)", lFutureAToSet, lFutureATimestamp),
            0
        );

        vm.warp(lFutureATimestamp);

        // act
        _factory.rawCall(
            address(_hybridPool),
            abi.encodeWithSignature("stopRampA()"),
            0
        );

        // assert
        (uint64 lInitialA, uint64 lFutureA, uint64 lInitialATime, uint64 lFutureATime) = _hybridPool.ampData();
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
            address(_hybridPool),
            abi.encodeWithSignature("rampA(uint64,uint64)", lFutureAToSet, lFutureATimestamp),
            0
        );

        // assert
        assertEq(_hybridPool.getCurrentA(), 1000);

        // warp to the midpoint between the initialATime and futureATime
        vm.warp((lFutureATimestamp + block.timestamp) / 2);
        assertEq(_hybridPool.getCurrentA(), (1000 + lFutureAToSet) / 2);

        // warp to the end
        vm.warp(lFutureATimestamp);
        assertEq(_hybridPool.getCurrentA(), lFutureAToSet);
    }

    function testRampA_SwappingDuringRampingUp(uint256 aSeed, uint64 aFutureA, uint64 aDuration, uint128 aSwapAmount) public
    {
        // arrange
        uint64 lFutureAToSet = uint64(bound(aFutureA, _hybridPool.getCurrentA(), StableMath.MAX_A));
        uint256 lMinRampDuration = lFutureAToSet / _hybridPool.getCurrentA() * 1 days;
        uint256 lMaxRampDuration = 30 days; // 1 month
        uint64 lCurrentTimestamp = uint64(block.timestamp);
        uint64 lFutureATimestamp = lCurrentTimestamp + uint64(bound(aDuration, lMinRampDuration, lMaxRampDuration));
        uint256 lAmountToSwap = aSwapAmount / 2;

        // act
        _factory.rawCall(
            address(_hybridPool),
            abi.encodeWithSignature("rampA(uint64,uint64)", lFutureAToSet, lFutureATimestamp),
            0
        );

        uint256 lAmountOutBeforeRamp = _hybridPool.getAmountOut(address(_tokenA), lAmountToSwap);
        uint64 lRemainingTime = lFutureATimestamp - lCurrentTimestamp;

        uint64 lCheck1 = uint64(bound(aSeed, 0, lRemainingTime));
        skip(lCheck1);
        uint256 lAmountOutT1 = _hybridPool.getAmountOut(address(_tokenA), lAmountToSwap);

        lRemainingTime -= lCheck1;
        uint64 lCheck2 = uint64(bound(uint256(keccak256(abi.encode(lCheck1))), 0, lRemainingTime));
        skip(lCheck2);
        uint256 lAmountOutT2 = _hybridPool.getAmountOut(address(_tokenA), lAmountToSwap);

        lRemainingTime -= lCheck2;
        uint64 lCheck3 = uint64(bound(uint256(keccak256(abi.encode(lCheck2))), 0, lRemainingTime));
        skip(lCheck3);
        uint256 lAmountOutT3 = _hybridPool.getAmountOut(address(_tokenA), lAmountToSwap);

        lRemainingTime -= lCheck3;
        skip(lRemainingTime);
        uint256 lAmountOutT4 = _hybridPool.getAmountOut(address(_tokenA), lAmountToSwap);

        // assert - output amount over time should be increasing or be within 1 due to rounding error
        assertTrue(lAmountOutT1 >= lAmountOutBeforeRamp || MathUtils.within1(lAmountOutT1, lAmountOutBeforeRamp));
        assertTrue(lAmountOutT2 >= lAmountOutT1         || MathUtils.within1(lAmountOutT2, lAmountOutT1));
        assertTrue(lAmountOutT3 >= lAmountOutT2         || MathUtils.within1(lAmountOutT3, lAmountOutT2));
        assertTrue(lAmountOutT4 >= lAmountOutT3         || MathUtils.within1(lAmountOutT4, lAmountOutT3));
    }

    function testRampA_SwappingDuringRampingDown(uint256 aSeed, uint64 aFutureA, uint64 aDuration, uint128 aSwapAmount) public
    {
        // arrange
        uint64 lFutureAToSet = uint64(bound(aFutureA, StableMath.MIN_A, _hybridPool.getCurrentA()));
        uint256 lMinRampDuration = _hybridPool.getCurrentA() / lFutureAToSet * 1 days;
        uint256 lMaxRampDuration = 1000 days;
        uint64 lCurrentTimestamp = uint64(block.timestamp);
        uint64 lFutureATimestamp = lCurrentTimestamp + uint64(bound(aDuration, lMinRampDuration, lMaxRampDuration));
        uint256 lAmountToSwap = aSwapAmount / 2;

         // act
        _factory.rawCall(
            address(_hybridPool),
            abi.encodeWithSignature("rampA(uint64,uint64)", lFutureAToSet, lFutureATimestamp),
            0
        );

        uint256 lAmountOutBeforeRamp = _hybridPool.getAmountOut(address(_tokenA), lAmountToSwap);
        uint64 lRemainingTime = lFutureATimestamp - lCurrentTimestamp;

        uint64 lCheck1 = uint64(bound(aSeed, 0, lRemainingTime));
        skip(lCheck1);
        uint256 lAmountOutT1 = _hybridPool.getAmountOut(address(_tokenA), lAmountToSwap);

        lRemainingTime -= lCheck1;
        uint64 lCheck2 = uint64(bound(uint256(keccak256(abi.encode(lCheck1))), 0, lRemainingTime));
        skip(lCheck2);
        uint256 lAmountOutT2 = _hybridPool.getAmountOut(address(_tokenA), lAmountToSwap);

        lRemainingTime -= lCheck2;
        uint64 lCheck3 = uint64(bound(uint256(keccak256(abi.encode(lCheck1))), 0, lRemainingTime));
        skip(lCheck3);
        uint256 lAmountOutT3 = _hybridPool.getAmountOut(address(_tokenA), lAmountToSwap);

        lRemainingTime -= lCheck3;
        skip(lRemainingTime);
        uint256 lAmountOutT4 = _hybridPool.getAmountOut(address(_tokenA), lAmountToSwap);

        // assert - output amount over time should be decreasing or within 1 due to rounding error
        assertTrue(lAmountOutT1 <= lAmountOutBeforeRamp || MathUtils.within1(lAmountOutT1, lAmountOutBeforeRamp));
        assertTrue(lAmountOutT2 <= lAmountOutT1         || MathUtils.within1(lAmountOutT2, lAmountOutT1));
        assertTrue(lAmountOutT3 <= lAmountOutT2         || MathUtils.within1(lAmountOutT3, lAmountOutT2));
        assertTrue(lAmountOutT4 <= lAmountOutT3         || MathUtils.within1(lAmountOutT4, lAmountOutT3));
    }
}
