// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

import { GenericFactory } from "src/GenericFactory.sol";
import { Create2Lib } from "src/libraries/Create2Lib.sol";

contract BaseScript is Script {
    bytes private _factoryCode = vm.getCode("out/GenericFactory.sol/GenericFactory.json");

    address internal _create2Factory = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    GenericFactory internal _factory;

    function _setup(uint256 aPrivateKey) internal {

        address lDerivedAddress = vm.rememberKey(aPrivateKey);

        _factory = GenericFactory(
            Create2Lib.computeAddress(
                _create2Factory,
                abi.encodePacked(type(GenericFactory).creationCode, abi.encode(lDerivedAddress)),
                bytes32(uint256(0))
            )
        );

        if (address(_factory).code.length == 0) {
            vm.broadcast(aPrivateKey);
            GenericFactory lFactory = new GenericFactory{salt: bytes32(uint256(0))}(lDerivedAddress);

            require(lFactory == _factory, "Create2 Address Mismatch");
        }
    }
}
