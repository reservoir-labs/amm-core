// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.13;

import { IERC20 } from "@openzeppelin/token/ERC20/IERC20.sol";

import { IUniswapV2Pair } from "src/interfaces/IUniswapV2Pair.sol";
import { IAssetManager } from "src/interfaces/IAssetManager.sol";

contract AssetManager is IAssetManager
{
    mapping(address => mapping(address => uint112)) public getBalance;

    function adjustManagement(IUniswapV2Pair aPair, int224 aToken0Amount, int224 aToken1Amount) external
    {
        require(aToken0Amount != type(int224).min && aToken1Amount != type(int224).min, "AM: OVERFLOW");

        if (aToken0Amount >= 0) {
            uint112 lAbs = uint112(uint256(int256(aToken0Amount)));

            getBalance[address(aPair)][aPair.token0()] += lAbs;
        }
        else {
            uint112 lAbs = uint112(uint256(int256(-aToken0Amount)));

            IERC20(aPair.token0()).approve(address(aPair), lAbs);
            getBalance[address(aPair)][aPair.token0()] -= lAbs;
        }
        if (aToken1Amount >= 0) {
            uint112 lAbs = uint112(uint256(int256(aToken1Amount)));

            getBalance[address(aPair)][aPair.token1()] += lAbs;
        }
        else {
            uint112 lAbs = uint112(uint256(int256(-aToken1Amount)));

            IERC20(aPair.token1()).approve(address(aPair), lAbs);
            getBalance[address(aPair)][aPair.token1()] -= lAbs;
        }

        aPair.adjustManagement(aToken0Amount, aToken1Amount);
    }

    function adjustBalance(address aOwner, address aToken, uint112 aNewAmount) external
    {
        getBalance[aOwner][aToken] = aNewAmount;
    }
}
