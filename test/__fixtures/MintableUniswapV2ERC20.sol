// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { UniswapV2ERC20 } from "src/UniswapV2ERC20.sol";

contract MintableUniswapV2ERC20 is UniswapV2ERC20 {
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
