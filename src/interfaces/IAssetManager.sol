// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import { ERC20 } from "solmate/tokens/ERC20.sol";

import { IAssetManagedPair } from "src/interfaces/IAssetManagedPair.sol";

interface IAssetManager {
    function getBalance(IAssetManagedPair owner, ERC20 token) external returns (uint256 tokenBalance);

    /// @notice called by the pair after mint/burn events to automatically re-balance the amount managed
    /// according to the lower and upper thresholds
    function afterLiquidityEvent() external;

    /// @notice called by the pair when it requires assets managed by the manager to be returned to the pair
    /// in order to fulfill swap requests or burn requests
    function returnAsset(bool aToken0, uint256 aAmount) external;
}
