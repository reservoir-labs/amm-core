/* solhint-disable reason-string */
pragma solidity ^0.8.0;

import { ERC20 } from "solmate/tokens/ERC20.sol";

import { ReservoirPair } from "src/ReservoirPair.sol";

interface IAssetManager {
    function getBalance(ReservoirPair owner, ERC20 token) external returns (uint104 tokenBalance);
    function afterLiquidityEvent() external;
    function returnAsset(bool aToken0, uint256 aAmount) external;
}
