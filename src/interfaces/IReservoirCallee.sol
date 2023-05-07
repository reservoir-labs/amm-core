// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

interface IReservoirCallee {
    /// @param sender user that initiated the swap and is triggering the callback
    /// @param amount0 positive indicates the amount out (received by callee), negative indicates the amount in (owed by callee)
    /// @param amount1 positive indicates the amount out (received by callee), negative indicates the amount in (owed by callee)
    /// @param data provided by the user is returned as part of the callback
    function reservoirCall(address sender, int256 amount0, int256 amount1, bytes calldata data) external;
}
