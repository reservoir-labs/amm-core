// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.13;

import { GenericFactory } from "src/GenericFactory.sol";

library FactoryStoreLib
{
    function read(GenericFactory aFactory, string memory aKey) internal view returns (bytes32)
    {
        return aFactory.get(keccak256(abi.encodePacked(aKey)));
    }
}
