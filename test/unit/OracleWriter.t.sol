pragma solidity ^0.8.0;

import "test/__fixtures/BaseTest.sol";

import { IOracleWriter } from "src/interfaces/IOracleWriter.sol";

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
}
