pragma solidity 0.8.13;

interface IComptroller {
    function allMarkets(uint256 index) external view returns (address);
    function getAllMarkets() external view returns (address[] memory);
}
