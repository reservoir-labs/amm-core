pragma solidity 0.8.13;

import { Ownable } from "@openzeppelin/access/Ownable.sol";

import { IERC20 } from "@openzeppelin/interfaces/IERC20.sol";
import { IAssetManager } from "src/interfaces/IAssetManager.sol";
import { IUniswapV2Pair } from "src/interfaces/IUniswapV2Pair.sol";
import { IStrategy } from "src/interfaces/IStrategy.sol";

contract AssetManager is IAssetManager, Ownable {

    /// @dev maps from the address of the pairs to a token (of the pair) to an array of strategies
    mapping(address => mapping(address => IStrategy[])) public strategies;

    constructor() {}

    function addStrategy(address aPair, address aToken, IStrategy aStrategy) external onlyOwner {
        require(aPair != address(0), "PAIR ADDRESS ZERO");
        require(address(aStrategy) != address(0), "STRATEGY ADDRESS ZERO");

        strategies[aPair][aToken].push(aStrategy);
    }

    function getBalance(address aOwner, address aToken) external returns (uint112 tokenBalance) {
        IStrategy[] memory lStrategies = strategies[aOwner][aToken];
        for (uint i = 0; i < lStrategies.length; ++i) {
            tokenBalance += lStrategies[i].getBalance();
        }
    }

    // optimization: could we cut the intermediate step of transferring to the AM first before transferring to the destination
    // and instead transfer it from the pair to the destination instead?
    function adjustManagement(address aPair, int256 aAmount0Change, int256 aAmount1Change, address aDestination) external onlyOwner {

        // transfer tokens from the pair
        IUniswapV2Pair(aPair).adjustManagement(aAmount0Change, aAmount1Change);

        // sanity - mainly to ensure we don't get more token than we expect and end up with some stuck within the contract
        // can remove if deemed unnecessary in the future
        address token0 = IUniswapV2Pair(aPair).token0();
        address token1 = IUniswapV2Pair(aPair).token1();

        require(IERC20(token0).balanceOf(address(this)) == uint256(aAmount0Change), "TOKEN0 AMOUNT MISMATCH");
        require(IERC20(token1).balanceOf(address(this)) == uint256(aAmount1Change), "TOKEN1 AMOUNT MISMATCH");

        // transfer the managed tokens to the destination
        // safe to cast int256 to uint256?
//        IERC20(aToken).transfer(aDestination, uint256(aAmount));
    }
}
