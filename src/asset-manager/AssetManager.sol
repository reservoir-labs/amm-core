pragma solidity 0.8.13;

import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/interfaces/IERC20.sol";

import { IAssetManager } from "src/interfaces/IAssetManager.sol";
import { IUniswapV2Pair } from "src/interfaces/IUniswapV2Pair.sol";
import { CErc20Interface } from "src/interfaces/CErc20Interface.sol";
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
    function adjustManagement(address aPair, int256 aAmount0Change, int256 aAmount1Change, address aCounterParty) external onlyOwner {

        // withdrawal from the counterparty
        if (aAmount0Change < 0) {

        }
        if (aAmount1Change < 0) {

        }

        // transfer tokens from the pair
        IUniswapV2Pair(aPair).adjustManagement(aAmount0Change, aAmount1Change);

        IERC20 token0 = IERC20(IUniswapV2Pair(aPair).token0());
        IERC20 token1 = IERC20(IUniswapV2Pair(aPair).token1());

        // sanity - mainly to ensure we don't get more token than we expect and end up with some stuck within the contract
        // can remove if deemed unnecessary in the future
        require(token0.balanceOf(address(this)) == uint256(aAmount0Change), "TOKEN0 AMOUNT MISMATCH");
        require(token1.balanceOf(address(this)) == uint256(aAmount1Change), "TOKEN1 AMOUNT MISMATCH");

        // transfer the managed tokens to the destination
        // safe to cast int256 to uint256?
        // not needed as the pair will perform the transfer
        if (aAmount0Change > 0) {
            token0.approve(aCounterParty, uint256(aAmount0Change));
            uint256 res = CErc20Interface(aCounterParty).mint(uint256(aAmount0Change));
            require(res == 0, "MINT DID NOT SUCCEED");
        }
        if (aAmount1Change > 0) {
            token1.approve(aCounterParty, uint256(aAmount1Change));
            uint256 res = CErc20Interface(aCounterParty).mint(uint256(aAmount1Change));
            require(res == 0, "MINT DID NOT SUCCEED");
        }
    }

    function trackCounterparties() internal {

    }
}
