// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { ERC20 } from "solmate/tokens/ERC20.sol";

import { IAssetManager } from "src/interfaces/IAssetManager.sol";
import { ReservoirPair } from "src/ReservoirPair.sol";

contract AssetManagerReenter is IAssetManager {
    mapping(ReservoirPair => mapping(ERC20 => uint104)) public _getBalance;

    // this is solely to test reentrancy for ReservoirPair::mint/burn when the pair syncs
    // with the asset manager at the beginning of the functions
    function getBalance(ReservoirPair, ERC20) external returns (uint104) {
        ReservoirPair(msg.sender).mint(address(this));
        return 0;
    }

    function adjustManagement(ReservoirPair aPair, int256 aToken0Amount, int256 aToken1Amount) external {
        require(aToken0Amount != type(int224).min && aToken1Amount != type(int224).min, "AM: OVERFLOW");

        if (aToken0Amount >= 0) {
            uint104 lAbs = uint104(uint256(int256(aToken0Amount)));

            _getBalance[aPair][aPair.token0()] += lAbs;
        } else {
            uint104 lAbs = uint104(uint256(int256(-aToken0Amount)));

            aPair.token0().approve(address(aPair), lAbs);
            _getBalance[aPair][aPair.token0()] -= lAbs;
        }
        if (aToken1Amount >= 0) {
            uint104 lAbs = uint104(uint256(int256(aToken1Amount)));

            _getBalance[aPair][aPair.token1()] += lAbs;
        } else {
            uint104 lAbs = uint104(uint256(int256(-aToken1Amount)));

            aPair.token1().approve(address(aPair), lAbs);
            _getBalance[aPair][aPair.token1()] -= lAbs;
        }

        aPair.adjustManagement(aToken0Amount, aToken1Amount);
    }

    function adjustBalance(ReservoirPair aOwner, ERC20 aToken, uint104 aNewAmount) external {
        _getBalance[aOwner][aToken] = aNewAmount;
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
