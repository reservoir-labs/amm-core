pragma solidity ^0.8.0;

import "test/__fixtures/BaseTest.sol";

import { IOracleWriter, Observation } from "src/interfaces/IOracleWriter.sol";
import { LogCompression } from "src/libraries/LogCompression.sol";
import { FactoryStoreLib } from "src/libraries/FactoryStore.sol";
import { GenericFactory } from "src/GenericFactory.sol";

contract OracleWriterTest is BaseTest {
    using FactoryStoreLib for GenericFactory;

    event OracleCallerChanged(address oldCaller, address newCaller);
    event AllowedChangePerSecondChanged(uint oldAllowedChangePerSecond, uint newAllowedChangePerSecond);

    IOracleWriter[] internal _pairs;
    IOracleWriter internal _pair;

    function setUp() public {
        _pairs.push(_constantProductPair);
        _pairs.push(_stablePair);
    }

    modifier allPairs() {
        for (uint i = 0; i < _pairs.length; ++i) {
            uint lBefore = vm.snapshot();
            _pair = _pairs[i];
            _;
            vm.revertTo(lBefore);
        }
    }

    function testObservation_NotOracleCaller(uint aIndex) external allPairs {
        // assume
        uint lIndex = bound(aIndex, 0, type(uint16).max);

        // act & assert
        vm.expectRevert("OW: NOT_ORACLE_CALLER");
        _pair.observation(lIndex);
    }

    function testUpdateOracleCaller() external allPairs {
        // arrange
        address lNewOracleCaller = address(0x555);
        _factory.write("Shared::oracleCaller", lNewOracleCaller);

        // act
        vm.expectEmit(true, true, false, false);
        emit OracleCallerChanged(address(_oracleCaller), lNewOracleCaller);
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

    function testAllowedChangePerSecond_Default() external allPairs {
        // assert
        assertEq(_pair.allowedChangePerSecond(), DEFAULT_ALLOWED_CHANGE_PER_SECOND);
    }

    function testSetAllowedChangePerSecond_OnlyFactory() external allPairs {
        // act & assert
        vm.expectRevert();
        _pair.setAllowedChangePerSecond(1);

        vm.prank(address(_factory));
        vm.expectEmit(true, true, false, false);
        emit AllowedChangePerSecondChanged(0.01e18, 1);
        _pair.setAllowedChangePerSecond(1);
        assertEq(_pair.allowedChangePerSecond(), 1);
    }

    function testSetAllowedChangePerSecond_TooLow() external allPairs {
        // act & assert
        vm.prank(address(_factory));
        vm.expectRevert("OW: INVALID_CHANGE_PER_SECOND");
        _pair.setAllowedChangePerSecond(0);
    }

    function testSetAllowedChangePerSecond_TooHigh(uint aAllowedChangePerSecond) external allPairs {
        // assume
        uint lAllowedChangePerSecond = bound(aAllowedChangePerSecond, 0.01e18 + 1, type(uint).max);

        // act & assert
        vm.prank(address(_factory));
        vm.expectRevert("OW: INVALID_CHANGE_PER_SECOND");
        _pair.setAllowedChangePerSecond(lAllowedChangePerSecond);
    }

    function testOracle_CompareLiquidityTwoCurves_Balanced() external {
        // arrange
        _stepTime(12);

        // act
        _constantProductPair.sync();
        _stablePair.sync();

        // assert
        Observation memory lObsCP = _oracleCaller.observation(_constantProductPair, 0);
        Observation memory lObsSP = _oracleCaller.observation(_stablePair, 0);
        uint lUncompressedLiqCP = LogCompression.fromLowResLog(lObsCP.logAccLiquidity / 12);
        uint lUncompressedLiqSP = LogCompression.fromLowResLog(lObsSP.logAccLiquidity / 12);
        assertEq(lUncompressedLiqSP, lUncompressedLiqCP);
        assertEq(lObsCP.logAccRawPrice, lObsSP.logAccRawPrice);
    }

    function testOracle_SameReservesDiffPrice() external {
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

        // assert
        Observation memory lObsCP = _oracleCaller.observation(lCP, 0);
        Observation memory lObsSP = _oracleCaller.observation(lSP, 0);
        uint lUncompressedLiqCP = LogCompression.fromLowResLog(lObsCP.logAccLiquidity / 12);
        uint lUncompressedLiqSP = LogCompression.fromLowResLog(lObsSP.logAccLiquidity / 12);
        assertEq(lUncompressedLiqCP, lUncompressedLiqSP);
        if (lCP.token0() == address(_tokenB)) {
            assertGt(lObsSP.logAccRawPrice, lObsCP.logAccRawPrice);
        } else {
            assertGt(lObsCP.logAccRawPrice, lObsSP.logAccRawPrice);
        }
    }

    // this test case shows how different reserves in respective curves can result in the same price
    // and that for an oracle consumer, it would choose CP as the more trustworthy source as it has greater liquidity
    function testOracle_SamePriceDiffLiq() external {
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
        Observation memory lObsCP = _oracleCaller.observation(lCP, 0);
        Observation memory lObsSP = _oracleCaller.observation(lSP, 0);
        uint lUncompressedPriceCP = LogCompression.fromLowResLog(lObsCP.logAccRawPrice / 12);
        uint lUncompressedPriceSP = LogCompression.fromLowResLog(lObsSP.logAccRawPrice / 12);
        assertEq(lUncompressedPriceCP, lUncompressedPriceSP);
        assertGt(lObsCP.logAccLiquidity, lObsSP.logAccLiquidity);
    }

    // this test case demonstrates how the two curves can have identical liquidity and price recorded by the oracle
    function testOracle_SamePriceSameLiq() external {
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
        Observation memory lObsCP = _oracleCaller.observation(lCP, 0);
        Observation memory lObsSP = _oracleCaller.observation(lSP, 0);
        uint lUncompressedPriceCP = LogCompression.fromLowResLog(lObsCP.logAccRawPrice / 12);
        uint lUncompressedPriceSP = LogCompression.fromLowResLog(lObsSP.logAccRawPrice / 12);
        assertEq(lUncompressedPriceCP, lUncompressedPriceSP);
        assertEq(lObsCP.logAccLiquidity, lObsSP.logAccLiquidity);
    }
}
