// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.13;

import { IGenericFactory } from "src/interfaces/IGenericFactory.sol";

library FactoryStoreLib
{
    function read(IGenericFactory aFactory, string memory aKey) internal view returns (bytes32)
    {
        return aFactory.get(keccak256(abi.encodePacked(aKey)));
    }
}
