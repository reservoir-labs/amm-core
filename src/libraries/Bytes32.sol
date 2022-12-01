// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

library Bytes32Lib {
    function toBytes32(bool aValue) internal pure returns (bytes32) {
        return aValue ? bytes32(uint(1)) : bytes32(uint(0));
    }

    function toBytes32(uint aValue) internal pure returns (bytes32) {
        return bytes32(aValue);
    }

    function toBytes32(int aValue) internal pure returns (bytes32) {
        return bytes32(uint(aValue));
    }

    function toBytes32(address aValue) internal pure returns (bytes32) {
        return bytes32(uint(uint160(aValue)));
    }

    function toBytes4(bytes32 aValue) internal pure returns (bytes4) {
        return bytes4(uint32(uint(aValue)));
    }

    function toBool(bytes32 aValue) internal pure returns (bool) {
        return uint(aValue) % 2 == 1;
    }

    function toUint64(bytes32 aValue) internal pure returns (uint64) {
        return uint64(uint(aValue));
    }

    function toUint256(bytes32 aValue) internal pure returns (uint) {
        return uint(aValue);
    }

    function toInt256(bytes32 aValue) internal pure returns (int) {
        return int(uint(aValue));
    }

    function toAddress(bytes32 aValue) internal pure returns (address) {
        return address(uint160(uint(aValue)));
    }
}
