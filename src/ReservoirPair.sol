pragma solidity ^0.8.0;

import { ERC20 } from "solmate/tokens/ERC20.sol";

import { AssetManagedPair } from "src/asset-management/AssetManagedPair.sol";
import { OracleWriter, Observation } from "src/oracle/OracleWriter.sol";

abstract contract ReservoirPair is AssetManagedPair, OracleWriter {
    /// @notice Force reserves to match balances.
    function sync() external {
        (uint104 lReserve0, uint104 lReserve1, uint32 lBlockTimestampLast,) = _lockAndLoad();
        (lReserve0, lReserve1) = _syncManaged(lReserve0, lReserve1);

        _updateAndUnlock(_totalToken0(), _totalToken1(), lReserve0, lReserve1, lBlockTimestampLast);
    }

    /// @notice Force balances to match reserves.
    function skim(address aTo) external {
        (uint104 lReserve0, uint104 lReserve1, uint32 lBlockTimestampLast,) = _lockAndLoad();

        _checkedTransfer(token0, aTo, _totalToken0() - lReserve0, lReserve0, lReserve1);
        _checkedTransfer(token1, aTo, _totalToken1() - lReserve1, lReserve0, lReserve1);
        _unlock(lBlockTimestampLast);
    }

    // performs a transfer, if it fails, it attempts to retrieve assets from the
    // AssetManager before retrying the transfer
    function _checkedTransfer(ERC20 aToken, address aDestination, uint256 aAmount, uint256 aReserve0, uint256 aReserve1)
        internal
    {
        if (!_safeTransfer(address(aToken), aDestination, aAmount)) {
            uint256 tokenOutManaged = aToken == token0 ? token0Managed : token1Managed;
            uint256 reserveOut = aToken == token0 ? aReserve0 : aReserve1;
            if (reserveOut - tokenOutManaged < aAmount) {
                assetManager.returnAsset(aToken == token0, aAmount - (reserveOut - tokenOutManaged));
                require(_safeTransfer(address(aToken), aDestination, aAmount), "RP: TRANSFER_FAILED");
            } else {
                revert("RP: TRANSFER_FAILED");
            }
        }
    }

    // update reserves and, on the first call per block, price and liq accumulators
    function _updateAndUnlock(
        uint256 aBalance0,
        uint256 aBalance1,
        uint104 aReserve0,
        uint104 aReserve1,
        uint32 aBlockTimestampLast
    ) internal {
        require(aBalance0 <= type(uint104).max && aBalance1 <= type(uint104).max, "RP: OVERFLOW");

        uint32 lBlockTimestamp = uint32(_currentTime());
        uint32 lTimeElapsed;
        unchecked {
            lTimeElapsed = lBlockTimestamp - aBlockTimestampLast; // overflow is desired
        }
        if (lTimeElapsed > 0 && aReserve0 != 0 && aReserve1 != 0) {
            _updateOracle(aReserve0, aReserve1, lTimeElapsed, aBlockTimestampLast);
        }

        _slot0.reserve0 = uint104(aBalance0);
        _slot0.reserve1 = uint104(aBalance1);
        _writeSlot0Timestamp(lBlockTimestamp, false);

        emit Sync(uint104(aBalance0), uint104(aBalance1));
    }
}
