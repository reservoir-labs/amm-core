pragma solidity ^0.8.0;

import "test/__fixtures/BaseTest.sol";

import { IOracleWriter } from "src/interfaces/IOracleWriter.sol";
import { LogCompression } from "src/libraries/LogCompression.sol";

contract OracleWriterTest is BaseTest
{
    event AllowedChangePerSecondChanged(uint256 oldAllowedChangePerSecond, uint256 newAllowedChangePerSecond);

    IOracleWriter[] internal _pairs;
    IOracleWriter   internal _pair;

    function setUp() public
    {
        _pairs.push(_constantProductPair);
        _pairs.push(_stablePair);
    }

    modifier allPairs()
    {
        for (uint256 i = 0; i < _pairs.length; ++i) {
            uint256 lBefore = vm.snapshot();
            _pair = _pairs[i];
            _;
            vm.revertTo(lBefore);
        }
    }

    function testAllowedChangePerSecond_Default() external allPairs
    {
        // assert
        assertEq(_pair.allowedChangePerSecond(), DEFAULT_ALLOWED_CHANGE_PER_SECOND);
    }

    function testSetAllowedChangePerSecond_OnlyFactory() external allPairs
    {
        // act & assert
        vm.expectRevert();
        _pair.setAllowedChangePerSecond(1);

        vm.prank(address(_factory));
        vm.expectEmit(true, true, false, false);
        emit AllowedChangePerSecondChanged(0.01e18, 1);
        _pair.setAllowedChangePerSecond(1);
        assertEq(_pair.allowedChangePerSecond(), 1);
    }

    function testSetAllowedChangePerSecond_TooLow() external allPairs
    {
        // act & assert
        vm.prank(address(_factory));
        vm.expectRevert("OW: INVALID_CHANGE_PER_SECOND");
        _pair.setAllowedChangePerSecond(0);
    }

    function testSetAllowedChangePerSecond_TooHigh(uint256 aAllowedChangePerSecond) external allPairs
    {
        // assume
        uint256 lAllowedChangePerSecond = bound(aAllowedChangePerSecond, 0.01e18 + 1, type(uint256).max);

        // act & assert
        vm.prank(address(_factory));
        vm.expectRevert("OW: INVALID_CHANGE_PER_SECOND");
        _pair.setAllowedChangePerSecond(lAllowedChangePerSecond);
    }

    function testOracle_CompareLiquidityTwoCurves_Balanced() external
    {
        // arrange
        _stepTime(12);

        // act
        _constantProductPair.sync();
        _stablePair.sync();

        // assert
        (int112 lAccRawPriceCP, , int56 lAccLogLiqCP, ) = _constantProductPair.observations(0);
        (int112 lAccRawPriceSP, , int56 lAccLogLiqSP, ) = _stablePair.observations(0);
        uint256 lUncompressedLiqCP = LogCompression.fromLowResLog(lAccLogLiqCP / 12);
        uint256 lUncompressedLiqSP = LogCompression.fromLowResLog(lAccLogLiqSP / 12);
        assertEq(lUncompressedLiqSP, lUncompressedLiqCP);
        assertEq(lAccRawPriceCP, lAccRawPriceSP);
    }

    function testOracle_CompareLiquidityTwoCurves_UnBalancedDiffPrice() external
    {
        // arrange
        ConstantProductPair lCP = ConstantProductPair(_createPair(address(_tokenB), address(_tokenC), 0));
        StablePair lSP          = StablePair(_createPair(address(_tokenB), address(_tokenC), 1));

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
        (, , int56 lAccLogLiqCP, ) = lCP.observations(0);
        (, , int56 lAccLogLiqSP, ) = lSP.observations(0);
        uint256 lUncompressedLiqCP = LogCompression.fromLowResLog(lAccLogLiqCP / 12);
        uint256 lUncompressedLiqSP = LogCompression.fromLowResLog(lAccLogLiqSP / 12);
        assertEq(lUncompressedLiqCP, lUncompressedLiqSP);
    }

    // this test case shows how different reserves in respective curves can result in the same price
    // and that for an oracle consumer, it would choose CP as the more trustworthy source as it has greater liquidity
    function testOracle_SamePriceDiffReserves() external
    {
        // arrange
        ConstantProductPair lCP = ConstantProductPair(_createPair(address(_tokenB), address(_tokenC), 0));
        StablePair lSP          = StablePair(_createPair(address(_tokenB), address(_tokenC), 1));

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
        (int112 lAccRawPriceCP, , int56 lAccLiqCP, ) = lCP.observations(0);
        (int112 lAccRawPriceSP, , int56 lAccLiqSP, ) = lSP.observations(0);
        uint256 lUncompressedPriceCP = LogCompression.fromLowResLog(lAccRawPriceCP / 12);
        uint256 lUncompressedPriceSP = LogCompression.fromLowResLog(lAccRawPriceSP / 12);
        assertEq(lUncompressedPriceCP, lUncompressedPriceSP);
        assertGt(lAccLiqCP, lAccLiqSP);
    }

    // this test case demonstrates how the two curves can have identical liquidity and price recorded by the oracle
    function testOracle_SamePriceSameLiq() external
    {
        // arrange
        ConstantProductPair lCP = ConstantProductPair(_createPair(address(_tokenB), address(_tokenC), 0));
        StablePair lSP          = StablePair(_createPair(address(_tokenB), address(_tokenC), 1));

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
        (int112 lAccRawPriceCP, , int56 lAccLiqCP, ) = lCP.observations(0);
        (int112 lAccRawPriceSP, , int56 lAccLiqSP, ) = lSP.observations(0);
        uint256 lUncompressedPriceCP = LogCompression.fromLowResLog(lAccRawPriceCP / 12);
        uint256 lUncompressedPriceSP = LogCompression.fromLowResLog(lAccRawPriceSP / 12);
        assertEq(lUncompressedPriceCP, lUncompressedPriceSP);
        assertEq(lAccLiqCP, lAccLiqSP);
    }
}
