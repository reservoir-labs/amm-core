// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

import { GenericFactory } from "src/GenericFactory.sol";
import { Create2Lib } from "src/libraries/Create2Lib.sol";

contract BaseScript is Script {
    GenericFactory internal _factory = GenericFactory(
        Create2Lib.computeAddress(address(msg.sender),
        abi.encodePacked(type(GenericFactory).creationCode,
        bytes32(bytes20(uint160(msg.sender)))),
        bytes32(0))
    );

    function _setup() internal {
        if (address(_factory).code.length == 0) {
            vm.broadcast();
            _factory = new GenericFactory{salt: bytes32(0)}(msg.sender);
        }
    }
}
