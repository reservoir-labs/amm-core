pragma solidity 0.8.13;

interface IStrategy {
    function getBalance() external returns (uint112 tokenBalance);
}
