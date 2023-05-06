// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

interface IReservoirCallee {
    /// @param sender the target address for the arbitrary data call in the case of a flash swap
    /// @param amount0 positive indicates the amount out (received by callee), negative indicates the amount in (owed by callee)
    /// @param amount1 positive indicates the amount out (received by callee), negative indicates the amount in (owed by callee)
    /// @param data the bytes that are provided in the case of a flash swap
    function reservoirCall(address sender, int256 amount0, int256 amount1, bytes calldata data) external;
}
