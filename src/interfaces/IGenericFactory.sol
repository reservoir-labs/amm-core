// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

interface IGenericFactory {
    function get(bytes32 key) external view returns (bytes32 value);
    function set(bytes32 key, bytes32 value) external;

    function addCurve(bytes calldata initCode) external returns (uint curveId);

    function allPairs() external view returns (address[] memory);
    function getPair(address tokenA, address tokenB, uint curveId) external view returns (address);
    function createPair(address tokenA, address tokenB, uint curveId) external returns (address);
}
