pragma solidity =0.8.13;

import "../curve/constant-product/UniswapV2ERC20.sol";

contract ERC20 is UniswapV2ERC20 {
    constructor(uint _totalSupply) {
        _mint(msg.sender, _totalSupply);
    }
}
