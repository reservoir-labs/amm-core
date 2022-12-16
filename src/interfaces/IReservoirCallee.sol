pragma solidity ^0.8.0;

interface IReservoirCallee {
    /// @param amount0 positive indicates the amount out (received by callee), negative indicates the amount in (owed by callee)
    /// @param amount1 positive indicates the amount out (received by callee), negative indicates the amount in (owed by callee)
    function reservoirCall(address sender, int256 amount0, int256 amount1, bytes calldata data) external;
}
