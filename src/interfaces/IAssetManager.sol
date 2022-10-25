/* solhint-disable reason-string */
pragma solidity 0.8.13;

import { IAssetManagedPair } from "src/interfaces/IAssetManagedPair.sol";

interface IAssetManager
{
    function getBalance(IAssetManagedPair owner, address token) external returns (uint112 tokenBalance);
    function afterLiquidityEvent() external;
    function returnAsset(address aToken, uint256 aAmount) external;
}
