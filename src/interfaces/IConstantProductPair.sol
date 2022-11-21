pragma solidity ^0.8.0;

interface IConstantProductPair {
    function kLast() external view returns (uint224);
}
