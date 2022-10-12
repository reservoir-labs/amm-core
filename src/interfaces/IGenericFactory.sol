// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.13;

interface IGenericFactory
{
    function get(bytes32 key) external view returns (bytes32 value);
    function set(bytes32 key, bytes32 value) external;

    function addCurve(bytes calldata initCode) external returns (uint256 curveId);

    function allPairs() external view returns (address[] memory);
    function getPair(address tokenA, address tokenB, uint256 curveId) external view returns (address);
    function createPair(address tokenA, address tokenB, uint256 curveId) external returns (address);
}
