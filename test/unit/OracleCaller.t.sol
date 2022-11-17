pragma solidity ^0.8.0;

import "test/__fixtures/BaseTest.sol";

import { IOracleWriter } from "src/interfaces/IOracleWriter.sol";

contract OracleCallerTest is BaseTest {

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

    function testObservation_NotWhitelisted(uint256 aIndex) external allPairs
    {
        // assume
        uint256 lIndex = bound(aIndex, 0, type(uint16).max);
        vm.startPrank(_alice);

        // act & assert
        vm.expectRevert("OC: NOT_WHITELISTED");
        _oracleCaller.observation(_pair, lIndex);
        vm.stopPrank();
    }
}
