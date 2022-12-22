pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/interfaces/IERC20.sol";

import { IAssetManagedPair, IAssetManager } from "src/interfaces/IAssetManagedPair.sol";
import { Pair } from "src/Pair.sol";

abstract contract AssetManagedPair is Pair, IAssetManagedPair {
    /*//////////////////////////////////////////////////////////////////////////
                                ASSET MANAGER
    //////////////////////////////////////////////////////////////////////////*/

    IAssetManager public assetManager;

    function setManager(IAssetManager manager) external onlyFactory {
        require(token0Managed == 0 && token1Managed == 0, "AMP: AM_STILL_ACTIVE");
        assetManager = manager;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                ASSET MANAGEMENT

    Asset management is supported via a two-way interface. The pool is able to
    ask the current asset manager for the latest view of the balances. In turn
    the asset manager can move assets in/out of the pool. This section
    implements the pool side of the equation. The manager's side is abstracted
    behind the IAssetManager interface.

    //////////////////////////////////////////////////////////////////////////*/

    uint104 public token0Managed;
    uint104 public token1Managed;

    function _totalToken0() internal view returns (uint256) {
        return IERC20(token0).balanceOf(address(this)) + uint256(token0Managed);
    }

    function _totalToken1() internal view returns (uint256) {
        return IERC20(token1).balanceOf(address(this)) + uint256(token1Managed);
    }

    function _handleReport(address aToken, uint104 aReserve, uint104 aPrevBalance, uint104 aNewBalance)
        private
        returns (uint104 rUpdatedReserve)
    {
        if (aNewBalance > aPrevBalance) {
            // report profit
            uint104 lProfit = aNewBalance - aPrevBalance;

            emit ProfitReported(aToken, lProfit);

            rUpdatedReserve = aReserve + lProfit;
        } else if (aNewBalance < aPrevBalance) {
            // report loss
            uint104 lLoss = aPrevBalance - aNewBalance;

            emit LossReported(aToken, lLoss);

            rUpdatedReserve = aReserve - lLoss;
        } else {
            // Balances are equal, return the original reserve.
            rUpdatedReserve = aReserve;
        }
    }

    function _syncManaged(uint104 aReserve0, uint104 aReserve1)
        internal
        returns (uint104 rReserve0, uint104 rReserve1)
    {
        if (address(assetManager) == address(0)) {
            // PERF: Is assigning to rReserve0 cheaper?
            return (aReserve0, aReserve1);
        }

        uint104 lToken0Managed = assetManager.getBalance(this, token0);
        uint104 lToken1Managed = assetManager.getBalance(this, token1);

        rReserve0 = _handleReport(token0, aReserve0, token0Managed, lToken0Managed);
        rReserve1 = _handleReport(token1, aReserve1, token1Managed, lToken1Managed);

        token0Managed = lToken0Managed;
        token1Managed = lToken1Managed;
    }

    function _managerCallback() internal {
        if (address(assetManager) == address(0)) {
            return;
        }
        // TODO: Unsure how I feel about this, probably okay but assetManager
        // is under our control so not sure if we can't just assume this call
        // won't fail?
        //
        // supplying to / withdrawing from 3rd party markets might fail
        try assetManager.afterLiquidityEvent() { } catch { } // solhint-disable-line no-empty-blocks
    }

    function adjustManagement(int256 token0Change, int256 token1Change) external {
        require(msg.sender == address(assetManager), "AMP: AUTH_NOT_MANAGER");
        require(token0Change != type(int256).min && token1Change != type(int256).min, "AMP: CAST_WOULD_OVERFLOW");

        if (token0Change > 0) {
            uint104 lDelta = uint104(uint256(int256(token0Change)));
            token0Managed += lDelta;
            IERC20(token0).transfer(msg.sender, lDelta);
        } else if (token0Change < 0) {
            uint104 lDelta = uint104(uint256(int256(-token0Change)));

            // solhint-disable-next-line reentrancy
            token0Managed -= lDelta;

            IERC20(token0).transferFrom(msg.sender, address(this), lDelta);
        }

        if (token1Change > 0) {
            uint104 lDelta = uint104(uint256(int256(token1Change)));

            // solhint-disable-next-line reentrancy
            token1Managed += lDelta;

            IERC20(token1).transfer(msg.sender, lDelta);
        } else if (token1Change < 0) {
            uint104 lDelta = uint104(uint256(int256(-token1Change)));

            // solhint-disable-next-line reentrancy
            token1Managed -= lDelta;

            IERC20(token1).transferFrom(msg.sender, address(this), lDelta);
        }
    }
}
