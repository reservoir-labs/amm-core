pragma solidity ^0.8.0;

import "test/__fixtures/BaseTest.sol";

import { ReservoirPair, Observation } from "src/ReservoirPair.sol";
import { LogCompression } from "src/libraries/LogCompression.sol";
import { FactoryStoreLib } from "src/libraries/FactoryStore.sol";
import { GenericFactory } from "src/GenericFactory.sol";
import { Constants } from "src/Constants.sol";

contract OracleWriterTest is BaseTest {
    using FactoryStoreLib for GenericFactory;

    event OracleCallerUpdated(address oldCaller, address newCaller);
    event MaxChangeRateUpdated(uint256 oldMaxChangeRate, uint256 newMaxChangeRate);

    ReservoirPair[] internal _pairs;
    ReservoirPair internal _pair;

    function setUp() public {
        _pairs.push(_constantProductPair);
        _pairs.push(_stablePair);
    }

    modifier allPairs() {
        for (uint256 i = 0; i < _pairs.length; ++i) {
            uint256 lBefore = vm.snapshot();
            _pair = _pairs[i];
            _;
            vm.revertTo(lBefore);
        }
    }

    function testObservation_NotOracleCaller(uint256 aIndex) external allPairs {
        // assume
        uint256 lIndex = bound(aIndex, 0, type(uint16).max);

        // act & assert
        vm.expectRevert("RP: NOT_ORACLE_CALLER");
        _pair.observation(lIndex);
    }

    function testUpdateOracleCaller() external allPairs {
        // arrange
        address lNewOracleCaller = address(0x555);
        _factory.write("Shared::oracleCaller", lNewOracleCaller);

        // act
        vm.expectEmit(false, false, false, true);
        emit OracleCallerUpdated(address(_oracleCaller), lNewOracleCaller);
        _pair.updateOracleCaller();

        // assert
        assertEq(_pair.oracleCaller(), lNewOracleCaller);
    }

    function testUpdateOracleCaller_NoChange() external allPairs {
        // arrange
        address lBefore = _pair.oracleCaller();

        // act
        _pair.updateOracleCaller();

        // assert
        assertEq(_pair.oracleCaller(), lBefore);
    }

    function testMaxChangeRate_Default() external allPairs {
        // assert
        assertEq(_pair.maxChangeRate(), Constants.DEFAULT_MAX_CHANGE_RATE);
    }

    function testSetMaxChangeRate_OnlyFactory() external allPairs {
        // act & assert
        vm.expectRevert();
        _pair.setMaxChangeRate(1);

        vm.prank(address(_factory));
        vm.expectEmit(false, false, false, true);
        emit MaxChangeRateUpdated(Constants.DEFAULT_MAX_CHANGE_RATE, 1);
        _pair.setMaxChangeRate(1);
        assertEq(_pair.maxChangeRate(), 1);
    }

    function testSetMaxChangeRate_TooLow() external allPairs {
        // act & assert
        vm.prank(address(_factory));
        vm.expectRevert("RP: INVALID_CHANGE_PER_SECOND");
        _pair.setMaxChangeRate(0);
    }

    function testSetMaxChangeRate_TooHigh(uint256 aMaxChangeRate) external allPairs {
        // assume
        uint256 lMaxChangeRate = bound(aMaxChangeRate, 0.01e18 + 1, type(uint256).max);

        // act & assert
        vm.prank(address(_factory));
        vm.expectRevert("RP: INVALID_CHANGE_PER_SECOND");
        _pair.setMaxChangeRate(lMaxChangeRate);
    }

    function testUpdateOracle_WriteOldPricesNotNew() external allPairs {
        // arrange
        uint256 lJumpAhead = 10;
        uint256 lOriginalPrice = 1e18; // both tokenA and B are INITIAL_MINT_AMOUNT
        (uint104 lReserve0,,,) = _pair.getReserves();
        assertEq(lReserve0, Constants.INITIAL_MINT_AMOUNT);
        _tokenA.mint(address(_pair), 10e18);

        // act - call sync to trigger a write to the oracle
        _stepTime(lJumpAhead);
        _pair.sync();

        // assert - make sure that the written observation is of the previous prices, not the new prices
        (uint256 lNewReserve0,,, uint16 lIndex) = _pair.getReserves();

        Observation memory lObs = _oracleCaller.observation(_pair, lIndex);
        assertEq(lNewReserve0, 110e18);
        assertApproxEqRel(LogCompression.fromLowResLog(lObs.logAccRawPrice / int88(int256(lJumpAhead))), lOriginalPrice, 0.0001e18);
    }

    function testUpdateOracle_LatestTimestampWritten(uint256 aJumpAhead) external allPairs {
        // assume
        uint256 lJumpAhead = bound(aJumpAhead, 10, type(uint16).max);

        // arrange
        uint256 lStartingTimestamp = block.timestamp;
        _stepTime(lJumpAhead);

        // act
        _tokenA.mint(address(_pair), 5e18);
        _pair.swap(5e18, true, address(this), "");

        // assert
        (,,, uint16 lIndex) = _pair.getReserves();
        Observation memory lObs = _oracleCaller.observation(_pair, lIndex);
        assertEq(lObs.timestamp, lStartingTimestamp + lJumpAhead);
    }

    function testOracle_SameReservesDiffPrice(uint32 aNewStartTime) external randomizeStartTime(aNewStartTime) {
        // arrange
        ConstantProductPair lCP = ConstantProductPair(_createPair(address(_tokenB), address(_tokenC), 0));
        StablePair lSP = StablePair(_createPair(address(_tokenB), address(_tokenC), 1));

        _tokenB.mint(address(lCP), 100e18);
        _tokenC.mint(address(lCP), 10e18);
        lCP.mint(address(this));

        _tokenB.mint(address(lSP), 100e18);
        _tokenC.mint(address(lSP), 10e18);
        lSP.mint(address(this));

        // act
        _stepTime(12);
        lCP.sync();
        lSP.sync();
        _stepTime(12);
        lCP.sync();
        lSP.sync();

        // assert
        Observation memory lObsCP0 = _oracleCaller.observation(lCP, 0);
        Observation memory lObsCP1 = _oracleCaller.observation(lCP, 1);
        Observation memory lObsSP0 = _oracleCaller.observation(lSP, 0);
        Observation memory lObsSP1 = _oracleCaller.observation(lSP, 1);
        if (lCP.token0() == IERC20(address(_tokenB))) {
            assertGt(lObsSP1.logAccRawPrice, lObsCP1.logAccRawPrice);
        } else {
            assertGt(lObsCP1.logAccRawPrice, lObsSP1.logAccRawPrice);
        }
    }

    // this test case shows how different reserves in respective curves can result in the same price
    // and that for an oracle consumer, it would choose CP as the more trustworthy source as it has greater liquidity
    function testOracle_SamePriceDiffLiq(uint32 aNewStartTime) external randomizeStartTime(aNewStartTime) {
        // arrange
        ConstantProductPair lCP = ConstantProductPair(_createPair(address(_tokenB), address(_tokenC), 0));
        StablePair lSP = StablePair(_createPair(address(_tokenB), address(_tokenC), 1));

        _tokenB.mint(address(lCP), 100e18);
        _tokenC.mint(address(lCP), 50e18);
        lCP.mint(address(this));

        _tokenB.mint(address(lSP), 100e18);
        _tokenC.mint(address(lSP), 1.1061e18);
        lSP.mint(address(this));

        // act
        _stepTime(12);
        lCP.sync();
        lSP.sync();
        _stepTime(12);
        lCP.sync();
        lSP.sync();

        // sanity - ensure that two oracle observations have been written at slots 0 and 1
        (,,, uint16 lIndex) = lCP.getReserves();
        assertEq(lIndex, 1);
        (,,, lIndex) = lSP.getReserves();
        assertEq(lIndex, 1);

        // assert
        Observation memory lObs0CP = _oracleCaller.observation(lCP, 0);
        Observation memory lObs1CP = _oracleCaller.observation(lCP, 1);
        Observation memory lObs0SP = _oracleCaller.observation(lSP, 0);
        Observation memory lObs1SP = _oracleCaller.observation(lSP, 1);
        uint256 lUncompressedPriceCP =
            LogCompression.fromLowResLog((lObs1CP.logAccRawPrice - lObs0CP.logAccRawPrice) / 12);
        uint256 lUncompressedPriceSP =
            LogCompression.fromLowResLog((lObs1SP.logAccRawPrice - lObs0SP.logAccRawPrice) / 12);
        assertEq(lUncompressedPriceCP, lUncompressedPriceSP);
    }

    // this test case demonstrates how the two curves can have identical liquidity and price recorded by the oracle
    function testOracle_SamePriceSameLiq(uint32 aNewStartTime) external randomizeStartTime(aNewStartTime) {
        // arrange
        ConstantProductPair lCP = ConstantProductPair(_createPair(address(_tokenB), address(_tokenC), 0));
        StablePair lSP = StablePair(_createPair(address(_tokenB), address(_tokenC), 1));

        _tokenB.mint(address(lCP), 7.436733153744324e18 * 2);
        _tokenC.mint(address(lCP), 7.436733153744324e18);
        lCP.mint(address(this));

        _tokenB.mint(address(lSP), 100e18);
        _tokenC.mint(address(lSP), 1.1061e18);
        lSP.mint(address(this));

        // act
        _stepTime(12);
        lCP.sync();
        lSP.sync();
        _stepTime(12);
        lCP.sync();
        lSP.sync();
        Observation memory lObsCP0 = _oracleCaller.observation(lCP, 0);
        Observation memory lObsCP1 = _oracleCaller.observation(lCP, 1);
        Observation memory lObsSP0 = _oracleCaller.observation(lSP, 0);
        Observation memory lObsSP1 = _oracleCaller.observation(lSP, 1);
        uint256 lUncompressedPriceCP =
            LogCompression.fromLowResLog((lObsCP1.logAccRawPrice - lObsCP0.logAccRawPrice) / 12);
        uint256 lUncompressedPriceSP =
            LogCompression.fromLowResLog((lObsSP1.logAccRawPrice - lObsSP0.logAccRawPrice) / 12);
        assertEq(lUncompressedPriceCP, lUncompressedPriceSP);
    }
}
