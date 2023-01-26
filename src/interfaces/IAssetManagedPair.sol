// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { ERC20 } from "solmate/tokens/ERC20.sol";

import { IAssetManager } from "src/interfaces/IAssetManager.sol";

interface IAssetManagedPair {
    function token0Managed() external returns (uint104);
    function token1Managed() external returns (uint104);

    function token0() external returns (ERC20);
    function token1() external returns (ERC20);

    function getReserves()
        external
        returns (uint104 rReserve0, uint104 rReserve1, uint32 rBlockTimestampLast, uint16 rIndex);

    function assetManager() external returns (IAssetManager);
    function setManager(IAssetManager manager) external;

    function adjustManagement(int256 token0Change, int256 token1Change) external;
}
