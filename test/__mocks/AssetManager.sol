// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { ERC20 } from "solmate/tokens/ERC20.sol";

import { IAssetManager } from "src/interfaces/IAssetManager.sol";
import { ReservoirPair } from "src/ReservoirPair.sol";

contract AssetManager is IAssetManager {
    mapping(ReservoirPair => mapping(ERC20 => uint256)) public getBalance;

    function adjustManagement(ReservoirPair aPair, int256 aToken0Amount, int256 aToken1Amount) external {
        require(aToken0Amount != type(int256).min && aToken1Amount != type(int256).min, "AM: OVERFLOW");

        if (aToken0Amount >= 0) {
            uint256 lAbs = uint256(int256(aToken0Amount));

            getBalance[aPair][aPair.token0()] += lAbs;
        } else {
            uint256 lAbs = uint256(int256(-aToken0Amount));

            aPair.token0().approve(address(aPair), lAbs);
            getBalance[aPair][aPair.token0()] -= lAbs;
        }
        if (aToken1Amount >= 0) {
            uint256 lAbs = uint256(int256(aToken1Amount));

            getBalance[aPair][aPair.token1()] += lAbs;
        } else {
            uint256 lAbs = uint256(int256(-aToken1Amount));

            aPair.token1().approve(address(aPair), lAbs);
            getBalance[aPair][aPair.token1()] -= lAbs;
        }

        aPair.adjustManagement(aToken0Amount, aToken1Amount);
    }

    function adjustBalance(ReservoirPair aOwner, ERC20 aToken, uint256 aNewAmount) external {
        getBalance[aOwner][aToken] = aNewAmount;
    }

    // solhint-disable-next-line no-empty-blocks
    function afterLiquidityEvent() external { }

    function returnAsset(bool aToken0, uint256 aAmount) external {
        (aToken0 ? ReservoirPair(msg.sender).token0() : ReservoirPair(msg.sender).token1()).approve(
            address(msg.sender), aAmount
        );
        ReservoirPair(msg.sender).adjustManagement(
            aToken0 ? -int256(aAmount) : int256(0), aToken0 ? int256(0) : -int256(aAmount)
        );
    }
}
