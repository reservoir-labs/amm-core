// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { IAssetManager, IERC20 } from "src/interfaces/IAssetManager.sol";
import { IAssetManagedPair } from "src/interfaces/IAssetManagedPair.sol";

contract AssetManager is IAssetManager {
    mapping(IAssetManagedPair => mapping(IERC20 => uint256)) public getBalance;

    function adjustManagement(IAssetManagedPair aPair, int256 aToken0Amount, int256 aToken1Amount) public {
        require(aToken0Amount != type(int256).min && aToken1Amount != type(int256).min, "AM: OVERFLOW");

        if (aToken0Amount < 0) {
            uint256 lAbs = uint256(-aToken0Amount);

            aPair.token0().approve(address(aPair), lAbs);
            getBalance[aPair][aPair.token0()] -= lAbs;
        }
        if (aToken1Amount < 0) {
            uint256 lAbs = uint256(-aToken1Amount);

            aPair.token1().approve(address(aPair), lAbs);
            getBalance[aPair][aPair.token1()] -= lAbs;
        }

        aPair.adjustManagement(aToken0Amount, aToken1Amount);

        if (aToken0Amount >= 0) {
            uint256 lAbs = uint256(aToken0Amount);

            getBalance[aPair][aPair.token0()] += lAbs;
        }
        if (aToken1Amount >= 0) {
            uint256 lAbs = uint256(aToken1Amount);

            getBalance[aPair][aPair.token1()] += lAbs;
        }
    }

    function adjustBalance(IAssetManagedPair aOwner, IERC20 aToken, uint256 aNewAmount) external {
        getBalance[aOwner][aToken] = aNewAmount;
    }

    // solhint-disable-next-line no-empty-blocks
    function afterLiquidityEvent() external { }

    function returnAsset(bool aToken0, uint256 aAmount) external {
        IAssetManagedPair lPair = IAssetManagedPair(msg.sender);
        int256 lAmount0Change = -int256(aToken0 ? aAmount : 0);
        int256 lAmount1Change = -int256(aToken0 ? 0 : aAmount);
        (aToken0 ? lPair.token0() : lPair.token1()).approve(address(msg.sender), aAmount);
        adjustManagement(lPair, lAmount0Change, lAmount1Change);
    }
}
