// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { ReservoirERC20 } from "src/ReservoirERC20.sol";

contract MintableReservoirERC20 is ReservoirERC20 {
    uint8 private _decimals;

    constructor(uint8 aDecimals) {
        _decimals = aDecimals;
    }

    function mint(address aReceiver, uint256 aAmount) external {
        _mint(aReceiver, aAmount);
    }

    function burn(address aSacrificer, uint256 aAmount) external {
        _burn(aSacrificer, aAmount);
    }
}
