pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import { LogCompression } from "src/libraries/LogCompression.sol";

contract LogCompressionTest is Test {
    address private _balancerLogCompression = address(200);

    constructor() {
        // we use getDeployedCode since the library contract is stateless
        bytes memory lBytecode = vm.getDeployedCode(
            "./reference/balancer-v2-monorepo/pkg/solidity-utils/artifacts/contracts/helpers/LogCompressionWrapper.sol/LogCompressionWrapper.json"
        );
        vm.etch(_balancerLogCompression, lBytecode);
    }

    function testToLowResLog(uint aValue) external {
        // act
        (bool lSuccess, bytes memory lRes) =
            _balancerLogCompression.staticcall(abi.encodeWithSignature("toLowResLog(uint256)", aValue));

        // assert
        if (lSuccess) {
            int lLocalRes = LogCompression.toLowResLog(aValue);
            int lDecoded = abi.decode(lRes, (int));
            assertEq(lLocalRes, lDecoded);
        } else {
            vm.expectRevert();
            LogCompression.toLowResLog(aValue);
        }
    }

    function testFromLowResLog(int aValue) external {
        // act
        (bool lSuccess, bytes memory lRes) =
            _balancerLogCompression.staticcall(abi.encodeWithSignature("fromLowResLog(int256)", aValue));

        // assert
        if (lSuccess) {
            uint lLocalRes = LogCompression.fromLowResLog(aValue);
            uint lDecoded = abi.decode(lRes, (uint));
            assertEq(lLocalRes, lDecoded);
        } else {
            vm.expectRevert();
            LogCompression.fromLowResLog(aValue);
        }
    }
}
