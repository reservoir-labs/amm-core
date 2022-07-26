pragma solidity 0.8.13;

import "libcompound/interfaces/CERC20.sol";

interface IComptroller {
    function allMarkets(uint256 index) external view returns (CERC20);
    function getAllMarkets() external view returns (CERC20[] memory);
}
