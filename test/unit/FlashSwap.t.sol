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

        console.logInt(aAmount0);
    }

    function testSwap_FlashSwap_ExactIn() external {
        // arrange
        int256 lSwapAmt = 1e18;

        // act
        uint256 lAmtOut = _constantProductPair.swap(lSwapAmt, true, address(this), "123123");

        // assert
        assertEq(_tokenB.balanceOf(address(this)), lAmtOut);
    }

    function testSwap_FlashSwap_ExactOut() external {
        // arrange
        int256 lSwapAmt = -50e18;

        // act
        _constantProductPair.swap(lSwapAmt, false, address(this), "123123");

        // assert
        assertEq(_tokenB.balanceOf(address(this)), uint256(-lSwapAmt));
    }
}
