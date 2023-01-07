pragma solidity ^0.8.0;

import { ERC20 } from "solmate/tokens/ERC20.sol";

import { IAssetManager } from "src/interfaces/IAssetManager.sol";
import { IPair } from "src/interfaces/IPair.sol";

interface IAssetManagedPair is IPair {
    function token0Managed() external returns (uint104);
    function token1Managed() external returns (uint104);

    function assetManager() external returns (IAssetManager);
    function setManager(IAssetManager manager) external;

    function adjustManagement(int256 token0Change, int256 token1Change) external;

    event ProfitReported(ERC20 token, uint104 amount);
    event LossReported(ERC20 token, uint104 amount);
}
