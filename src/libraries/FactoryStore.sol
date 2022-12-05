// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { IGenericFactory } from "src/interfaces/IGenericFactory.sol";
import { Bytes32Lib } from "src/libraries/Bytes32.sol";

library FactoryStoreLib {
    using Bytes32Lib for bool;
    using Bytes32Lib for uint256;
    using Bytes32Lib for int256;
    using Bytes32Lib for address;

    function read(IGenericFactory aFactory, string memory aKey) internal view returns (bytes32) {
        return aFactory.get(keccak256(abi.encodePacked(aKey)));
    }

    function write(IGenericFactory aFactory, string memory aKey, bool aValue) internal {
        aFactory.set(keccak256(abi.encodePacked(aKey)), aValue.toBytes32());
    }

    function write(IGenericFactory aFactory, string memory aKey, uint256 aValue) internal {
        aFactory.set(keccak256(abi.encodePacked(aKey)), aValue.toBytes32());
    }

    function write(IGenericFactory aFactory, string memory aKey, int256 aValue) internal {
        aFactory.set(keccak256(abi.encodePacked(aKey)), aValue.toBytes32());
    }

    function write(IGenericFactory aFactory, string memory aKey, address aValue) internal {
        aFactory.set(keccak256(abi.encodePacked(aKey)), aValue.toBytes32());
    }
}
