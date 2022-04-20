pragma solidity =0.8.13;

interface IUniswapV2Factory {
    function platformFeeTo() external view returns (address);
    function setPlatformFeeTo(address) external;

    function getPair(address tokenA, address tokenB) external view returns (address pair);
    function allPairs(uint) external view returns (address pair);
    function allPairsLength() external view returns (uint);

    function createPair(address tokenA, address tokenB) external returns (address pair);
}
