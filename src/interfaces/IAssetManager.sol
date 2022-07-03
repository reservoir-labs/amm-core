/* solhint-disable reason-string */
pragma solidity =0.8.13;

interface IAssetManager {
    function getBalance(address owner, address token) external returns (uint256 tokenBalance);
}
