pragma solidity ^0.8.0;

import { IReservoirCallee } from "src/interfaces/IReservoirCallee.sol";
import { MintableERC20 } from "test/__fixtures/MintableERC20.sol";
import { StablePair } from "src/curve/stable/StablePair.sol";
import "forge-std/console.sol";

contract MockRouter is IReservoirCallee {
    MintableERC20 internal _tokenA;
    MintableERC20 internal _tokenB;

    constructor (MintableERC20 tokenA, MintableERC20 tokenB)
    {
        _tokenA = tokenA;
        _tokenB = tokenB;
    }

    function swapCallback(uint amount0, uint amount1, bytes calldata data) external
    {
        _tokenA.mint(msg.sender, amount0);
        _tokenB.mint(msg.sender, amount1);
    }

    function mintCallback(uint amount0Owed, uint amount1Owed, bytes calldata data) external
    {
        _tokenA.mint(msg.sender, amount0Owed);
        _tokenB.mint(msg.sender, amount1Owed);
    }

    function mint(StablePair stablePair, address to, uint token0Amt, uint token1Amt) external
    {
        stablePair.mint(token0Amt, token1Amt, to, "");
    }

    function swap(StablePair stablePair, address to, int swapAmt, bool inOrOut) external returns (uint256 amountOut)
    {
        amountOut = stablePair.swap(swapAmt, inOrOut, to, "");
    }
}
