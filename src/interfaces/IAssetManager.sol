/* solhint-disable reason-string */
pragma solidity 0.8.13;

import { IAssetManagedPair } from "src/interfaces/IAssetManagedPair.sol";

interface IAssetManager
{
    function getBalance(IAssetManagedPair owner, address token) external returns (uint112 tokenBalance);
    function adjustManagement(IAssetManagedPair pair, int256 amount0Change, int256 amount1Change) external;
    function afterLiquidityEvent() external;
}
