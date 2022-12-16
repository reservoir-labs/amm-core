pragma solidity ^0.8.0;

import "test/__fixtures/BaseTest.sol";

import { IReservoirCallee } from "src/interfaces/IReservoirCallee.sol";

contract FlashSwapTest is BaseTest, IReservoirCallee {
    function reservoirCall(address aSender, int256 aAmount0, int256 aAmount1, bytes calldata aData) external {
        if (aAmount0 < 0) {
            _tokenA.mint(msg.sender, uint256(-aAmount0));
        } else if (aAmount1 < 0) {
            _tokenB.mint(msg.sender, uint256(-aAmount1));
        }
    }

    function testSwap_FlashSwap_ExactIn(uint256 aSwapAmt) external {
        // assume
        int256 lSwapAmt = int256(bound(aSwapAmt, 1, type(uint112).max / 2));

        // act
        uint256 lAmtOut = _constantProductPair.swap(lSwapAmt, true, address(this), "some bytes");

        // assert
        assertEq(_tokenB.balanceOf(address(this)), lAmtOut);
    }

    function testSwap_FlashSwap_ExactOut(uint256 aSwapAmt) external {
        // assume
        int256 lSwapAmt = -int256(bound(aSwapAmt, 1, INITIAL_MINT_AMOUNT / 2));

        // act
        _constantProductPair.swap(lSwapAmt, false, address(this), "some bytes");

        // assert
        assertEq(_tokenB.balanceOf(address(this)), uint256(-lSwapAmt));
    }
}
