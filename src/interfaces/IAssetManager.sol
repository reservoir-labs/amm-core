/* solhint-disable reason-string */
pragma solidity ^0.8.0;

import { ERC20 } from "solmate/tokens/ERC20.sol";

import { IAssetManagedPair } from "src/interfaces/IAssetManagedPair.sol";

interface IAssetManager {
    // TODO: `address token` -> `IERC20 token`
    function getBalance(IAssetManagedPair owner, ERC20 token) external returns (uint104 tokenBalance);
    function afterLiquidityEvent() external;
    function returnAsset(bool aToken0, uint256 aAmount) external;
}
