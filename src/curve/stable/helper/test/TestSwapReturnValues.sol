// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "../../../../interfaces/ISwap.sol";

contract TestSwapReturnValues {
    ISwap public swap;
    IERC20 public lpToken;
    uint8 public n;

    uint256 public constant MAX_INT = 2**256 - 1;

    constructor(
        ISwap swapContract,
        IERC20 lpTokenContract,
        uint8 numOfTokens
    ) public {
        swap = swapContract;
        lpToken = lpTokenContract;
        n = numOfTokens;

        // Pre-approve tokens
        for (uint8 i; i < n; i++) {
            swap.getToken(i).approve(address(swap), MAX_INT);
        }
        lpToken.approve(address(swap), MAX_INT);
    }

    function test_swap(
        uint8 tokenIndexFrom,
        uint8 tokenIndexTo,
        uint256 dx,
        uint256 minDy
    ) public {
        uint256 balanceBefore = swap.getToken(tokenIndexTo).balanceOf(
            address(this)
        );
        uint256 returnValue = swap.swap(
            tokenIndexFrom,
            tokenIndexTo,
            dx,
            minDy,
            block.timestamp
        );
        uint256 balanceAfter = swap.getToken(tokenIndexTo).balanceOf(
            address(this)
        );

        require(
            returnValue == balanceAfter - balanceBefore,
            "swap()'s return value does not match received amount"
        );
    }

    function test_addLiquidity(uint256[] calldata amounts, uint256 minToMint)
        public
    {
        uint256 balanceBefore = lpToken.balanceOf(address(this));
        uint256 returnValue = swap.addLiquidity(amounts, minToMint, MAX_INT);
        uint256 balanceAfter = lpToken.balanceOf(address(this));

        require(
            returnValue == balanceAfter - balanceBefore,
            "addLiquidity()'s return value does not match minted amount"
        );
    }

    function test_removeLiquidity(uint256 amount, uint256[] memory minAmounts)
        public
    {
        uint256[] memory balanceBefore = new uint256[](n);
        uint256[] memory balanceAfter = new uint256[](n);

        for (uint8 i = 0; i < n; i++) {
            balanceBefore[i] = swap.getToken(i).balanceOf(address(this));
        }

        uint256[] memory returnValue = swap.removeLiquidity(
            amount,
            minAmounts,
            MAX_INT
        );

        for (uint8 i = 0; i < n; i++) {
            balanceAfter[i] = swap.getToken(i).balanceOf(address(this));

            require(
                balanceAfter[i] - balanceBefore[i] == returnValue[i],
                "removeLiquidity()'s return value does not match received amounts of tokens"
            );
        }
    }

    function test_removeLiquidityImbalance(
        uint256[] calldata amounts,
        uint256 maxBurnAmount
    ) public {
        uint256 balanceBefore = lpToken.balanceOf(address(this));
        uint256 returnValue = swap.removeLiquidityImbalance(
            amounts,
            maxBurnAmount,
            MAX_INT
        );
        uint256 balanceAfter = lpToken.balanceOf(address(this));

        require(
            returnValue == balanceBefore - balanceAfter,
            "removeLiquidityImbalance()'s return value does not match burned lpToken amount"
        );
    }

    function test_removeLiquidityOneToken(
        uint256 tokenAmount,
        uint8 tokenIndex,
        uint256 minAmount
    ) public {
        uint256 balanceBefore = swap.getToken(tokenIndex).balanceOf(
            address(this)
        );
        uint256 returnValue = swap.removeLiquidityOneToken(
            tokenAmount,
            tokenIndex,
            minAmount,
            MAX_INT
        );
        uint256 balanceAfter = swap.getToken(tokenIndex).balanceOf(
            address(this)
        );

        require(
            returnValue == balanceAfter - balanceBefore,
            "removeLiquidityOneToken()'s return value does not match received token amount"
        );
    }
}
