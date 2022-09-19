pragma solidity 0.8.13;

interface IConstantProductPair {
    function kLast() external view returns (uint224);
}
