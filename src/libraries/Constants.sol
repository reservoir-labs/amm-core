// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { Create2Lib } from "src/libraries/Create2Lib.sol";
import { StableMintBurn } from "src/curve/stable/StableMintBurn.sol";

import "forge-std/console.sol";

library ConstantsLib {
    // TODO: to replace this with the actual production address once the deployer address / key has been decided
    // address public constant MINT_BURN_ADDRESS = 0xde10cb7b143e5637eaddfa55a9a41189d9810d0beb54480bcde2cd9af73bda02;

    function getMintBurnAddress() external view returns (address) {
        bytes memory lInitCode = bytes.concat(type(StableMintBurn).creationCode, abi.encode(0x2a9e8fa175F45b235efDdD97d2727741EF4Eee63), abi.encode(0x72384992222BE015DE0146a6D7E5dA0E19d2Ba49));
        address lComputed = Create2Lib.computeAddress(msg.sender, lInitCode, 0);
        return lComputed;
    }
}
