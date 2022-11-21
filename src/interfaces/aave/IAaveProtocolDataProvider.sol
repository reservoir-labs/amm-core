// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

interface IAaveProtocolDataProvider {
    function getReserveTokensAddresses(address asset)
    external
    view
    returns (
        address aTokenAddress,
        address stableDebtTokenAddress,
        address variableDebtTokenAddress
    );
}
