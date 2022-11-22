pragma solidity 0.8.13;

interface IReservoirCallee {
    function swapCallback(uint amount0Out, uint amount1Out, bytes calldata data) external;
    function mintCallback(uint amount0Owed, uint amount1Owed, bytes calldata data) external;
}
