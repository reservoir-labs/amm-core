pragma solidity ^0.8.0;

import "src/ReservoirERC20.sol";

contract TestERC20 is ReservoirERC20 {
    constructor(uint256 _totalSupply) {
        _mint(msg.sender, _totalSupply);
    }
}
