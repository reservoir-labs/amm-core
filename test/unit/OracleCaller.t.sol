pragma solidity ^0.8.0;

import "test/__fixtures/BaseTest.sol";

import { OracleWriter } from "src/oracle/OracleWriter.sol";

contract OracleCallerTest is BaseTest {
    event WhitelistChanged(address caller, bool whitelist);

    OracleWriter[] internal _pairs;
    OracleWriter internal _pair;

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

    function testObservation_NotWhitelisted(uint256 aIndex) external allPairs {
        // assume
        uint256 lIndex = bound(aIndex, 0, type(uint16).max);
        vm.startPrank(_alice);

        // act & assert
        vm.expectRevert("OC: NOT_WHITELISTED");
        _oracleCaller.observation(_pair, lIndex);
        vm.stopPrank();
    }

    function testWhitelistAddress() external allPairs {
        // act & assert
        vm.expectEmit(true, true, false, false);
        emit WhitelistChanged(_alice, true);
        _oracleCaller.whitelistAddress(_alice, true);

        // alice can call observation without reverting now
        vm.prank(_alice);
        _oracleCaller.observation(_pair, 0);
    }

    function testWhitelistAddress_NotOwner() external {
        // act & assert
        vm.prank(_bob);
        vm.expectRevert("UNAUTHORIZED");
        _oracleCaller.whitelistAddress(_cal, true);
    }
}
