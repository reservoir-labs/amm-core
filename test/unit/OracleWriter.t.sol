pragma solidity ^0.8.0;

import "test/__fixtures/BaseTest.sol";

import { IOracleWriter } from "src/interfaces/IOracleWriter.sol";

contract OracleWriterTest is BaseTest
{
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

    function testSetMaxChangePerSecond_OnlyFactory() external allPairs
    {
        // act & assert
        vm.expectRevert();
        _pair.setMaxChangePerSecond(1);

        vm.prank(address(_factory));
        _pair.setMaxChangePerSecond(1);
    }

    function testSetMaxChangePerSecond_TooLow() external allPairs
    {
        // act & assert
        vm.prank(address(_factory));
        vm.expectRevert("RP: INVALID_CHANGE_PER_SECOND");
        _pair.setMaxChangePerSecond(0);
    }

    function testSetMaxChangePerSecond_TooHigh() external allPairs
    {
        // act & assert
        vm.prank(address(_factory));
        vm.expectRevert("RP: INVALID_CHANGE_PER_SECOND");
        _pair.setMaxChangePerSecond(0.002e18);
    }
}
