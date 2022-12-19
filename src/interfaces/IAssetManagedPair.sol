pragma solidity ^0.8.0;

import { IAssetManager } from "src/interfaces/IAssetManager.sol";
import { IPair } from "src/interfaces/IPair.sol";

interface IAssetManagedPair is IPair {
    function token0Managed() external returns (uint104);
    function token1Managed() external returns (uint104);

    function assetManager() external returns (IAssetManager);
    function setManager(IAssetManager manager) external;

    function adjustManagement(int256 token0Change, int256 token1Change) external;

    event ProfitReported(address token, uint104 amount);
    event LossReported(address token, uint104 amount);
}
