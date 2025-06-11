// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { LogExpMath } from "src/libraries/LogExpMath.sol";

contract LogExpMathWrapper {
    function pow(uint256 aX, uint256 aY) external pure returns (uint256) {
        return LogExpMath.pow(aX, aY);
    }

    function exp(int256 aX) external pure returns (int256) {
        return LogExpMath.exp(aX);
    }

    function log(int256 aArg, int256 aBase) external pure returns (int256) {
        return LogExpMath.log(aArg, aBase);
    }

    function ln(int256 aX) external pure returns (int256) {
        return LogExpMath.ln(aX);
    }
}
