// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "@openzeppelin/token/ERC20/ERC20.sol";

contract MintableERC20 is ERC20 {
    uint8 private _decimals;

    constructor(string memory aName, string memory aSymbol, uint8 aDecimals) ERC20(aName, aSymbol) {
        _decimals = aDecimals;
    }

    function mint(address aReceiver, uint256 aAmount) external {
        _mint(aReceiver, aAmount);
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }
}
