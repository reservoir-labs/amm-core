/* solhint-disable reason-string */
pragma solidity ^0.8.0;

import { IAssetManagedPair } from "src/interfaces/IAssetManagedPair.sol";

interface IAssetManager {
    // TODO: `address token` -> `IERC20 token`
    function getBalance(IAssetManagedPair owner, address token) external returns (uint112 tokenBalance);
    function afterLiquidityEvent() external;
    function returnAsset(bool aToken0, uint256 aAmount) external;
}
