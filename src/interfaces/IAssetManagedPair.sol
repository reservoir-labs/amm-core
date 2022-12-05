pragma solidity ^0.8.0;

import { IAssetManager } from "src/interfaces/IAssetManager.sol";
import { IPair } from "src/interfaces/IPair.sol";

interface IAssetManagedPair is IPair {
    function token0Managed() external returns (uint112);
    function token1Managed() external returns (uint112);

    function adjustManagement(int256 token0Change, int256 token1Change) external;
    function assetManager() external returns (IAssetManager);
    function setManager(IAssetManager manager) external;

    event ProfitReported(address token, uint112 amount);
    event LossReported(address token, uint112 amount);
}
