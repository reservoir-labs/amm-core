// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/token/ERC20/IERC20.sol";

import { IConstantProductPair } from "src/interfaces/IConstantProductPair.sol";
import { IAssetManager } from "src/interfaces/IAssetManager.sol";
import { IAssetManagedPair } from "src/interfaces/IAssetManagedPair.sol";

contract AssetManager is IAssetManager {
    mapping(IAssetManagedPair => mapping(address => uint112)) public getBalance;

    function adjustManagement(IAssetManagedPair aPair, int aToken0Amount, int aToken1Amount) external {
        require(aToken0Amount != type(int224).min && aToken1Amount != type(int224).min, "AM: OVERFLOW");

        if (aToken0Amount >= 0) {
            uint112 lAbs = uint112(uint(int(aToken0Amount)));

            getBalance[aPair][aPair.token0()] += lAbs;
        } else {
            uint112 lAbs = uint112(uint(int(-aToken0Amount)));

            IERC20(aPair.token0()).approve(address(aPair), lAbs);
            getBalance[aPair][aPair.token0()] -= lAbs;
        }
        if (aToken1Amount >= 0) {
            uint112 lAbs = uint112(uint(int(aToken1Amount)));

            getBalance[aPair][aPair.token1()] += lAbs;
        } else {
            uint112 lAbs = uint112(uint(int(-aToken1Amount)));

            IERC20(aPair.token1()).approve(address(aPair), lAbs);
            getBalance[aPair][aPair.token1()] -= lAbs;
        }

        aPair.adjustManagement(aToken0Amount, aToken1Amount);
    }

    function adjustBalance(IAssetManagedPair aOwner, address aToken, uint112 aNewAmount) external {
        getBalance[aOwner][aToken] = aNewAmount;
    }

    // solhint-disable-next-line no-empty-blocks
    function afterLiquidityEvent() external { }

    // solhint-disable-next-line no-empty-blocks
    function returnAsset(bool aToken0, uint aAmount) external { }
}
