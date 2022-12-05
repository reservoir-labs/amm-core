pragma solidity ^0.8.0;

import "src/UniswapV2ERC20.sol";

contract TestERC20 is UniswapV2ERC20 {
    constructor(uint256 _totalSupply) {
        _mint(msg.sender, _totalSupply);
    }
}
