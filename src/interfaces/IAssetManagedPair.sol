pragma solidity 0.8.13;

import { IAssetManager } from "src/interfaces/IAssetManager.sol";

interface IAssetManagedPair {
    function adjustManagement(int256 token0Change, int256 token1Change) external;
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function assetManager() external returns (IAssetManager);
    function setManager(IAssetManager manager) external;
}
