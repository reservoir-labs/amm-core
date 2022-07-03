// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.13;

import { IERC20 } from "@openzeppelin/token/ERC20/IERC20.sol";

import { IUniswapV2Pair } from "src/interfaces/IUniswapV2Pair.sol";
import { IAssetManager } from "src/interfaces/IAssetManager.sol";

contract AssetManager is IAssetManager
{
    mapping(address => mapping(address => uint256)) public getBalance;

    function adjustInvestment(IUniswapV2Pair aPool, int256 aToken0Amount, int256 aToken1Amount) external
    {
        require(aToken0Amount != type(int256).min && aToken1Amount != type(int256).min, "overflow");

        if (aToken0Amount >= 0) {
            uint256 lAbs = uint256(aToken0Amount);

            getBalance[address(aPool)][aPool.token0()] += lAbs;
        }
        else {
            uint256 lAbs = uint256(-aToken0Amount);

            IERC20(aPool.token0()).approve(address(aPool), lAbs);
            getBalance[address(aPool)][aPool.token0()] -= lAbs;
        }
        if (aToken1Amount >= 0) {
            uint256 lAbs = uint256(aToken1Amount);

            getBalance[address(aPool)][aPool.token1()] += lAbs;
        }
        else {
            uint256 lAbs = uint256(-aToken1Amount);

            IERC20(aPool.token1()).approve(address(aPool), lAbs);
            getBalance[address(aPool)][aPool.token1()] -= lAbs;
        }

        aPool.adjustInvestment(aToken0Amount, aToken1Amount);
    }

    function adjustBalance(address aOwner, address aToken, uint256 aNewAmount) external
    {
        getBalance[aOwner][aToken] = aNewAmount;
    }
}
