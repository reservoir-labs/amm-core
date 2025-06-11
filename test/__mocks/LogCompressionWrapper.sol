pragma solidity ^0.8.0;

import { LogCompression } from "src/libraries/LogCompression.sol";

contract LogCompressionWrapper {
    function toLowResLog(uint256 aValue) external pure returns (int256) {
        return LogCompression.toLowResLog(aValue);
    }

    function fromLowResLog(int256 aValue) external pure returns (uint256) {
        return LogCompression.fromLowResLog(aValue);
    }
}
