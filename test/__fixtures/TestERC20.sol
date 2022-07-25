pragma solidity 0.8.13;

import "src/UniswapV2ERC20.sol";

contract TestERC20 is UniswapV2ERC20 {
    constructor(uint _totalSupply) {
        _mint(msg.sender, _totalSupply);
    }
}
