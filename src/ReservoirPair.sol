pragma solidity ^0.8.0;

import { AssetManagedPair } from "src/asset-management/AssetManagedPair.sol";
import { OracleWriter, Observation } from "src/oracle/OracleWriter.sol";

abstract contract ReservoirPair is AssetManagedPair, OracleWriter {
    modifier _nonReentrant() virtual;

    /// @notice Force reserves to match balances.
    function sync() external _nonReentrant {
        (uint104 lReserve0, uint104 lReserve1,,) = getReserves();

        _syncManaged();
        _update(_totalToken0(), _totalToken1(), lReserve0, lReserve1);
    }

    /// @notice Force balances to match reserves.
    function skim(address aTo) external _nonReentrant {
        (uint104 lReserve0, uint104 lReserve1,,) = getReserves();

        _checkedTransfer(token0, aTo, _totalToken0() - lReserve0, lReserve0, lReserve1);
        _checkedTransfer(token1, aTo, _totalToken1() - lReserve1, lReserve0, lReserve1);
    }

    // performs a transfer, if it fails, it attempts to retrieve assets from the
    // AssetManager before retrying the transfer
    function _checkedTransfer(
        address aToken,
        address aDestination,
        uint256 aAmount,
        uint256 aReserve0,
        uint256 aReserve1
    ) internal {
        if (!_safeTransfer(aToken, aDestination, aAmount)) {
            uint256 tokenOutManaged = aToken == token0 ? token0Managed : token1Managed;
            uint256 reserveOut = aToken == token0 ? aReserve0 : aReserve1;
            if (reserveOut - tokenOutManaged < aAmount) {
                assetManager.returnAsset(aToken == token0, aAmount - (reserveOut - tokenOutManaged));
                require(_safeTransfer(aToken, aDestination, aAmount), "RP: TRANSFER_FAILED");
            } else {
                revert("RP: TRANSFER_FAILED");
            }
        }
    }

    // update reserves and, on the first call per block, price and liq accumulators
    function _update(uint256 aBalance0, uint256 aBalance1, uint104 aReserve0, uint104 aReserve1) internal override {
        // TODO: Cache this load?
        (,, uint32 lBlockTimestampLast,) = getReserves();
        require(aBalance0 <= type(uint104).max && aBalance1 <= type(uint104).max, "CP: OVERFLOW");

        // TODO: Difference between this and just uint32(block.timestamp)? We
        //       don't always do mod in our codebase...
        uint32 lBlockTimestamp = uint32(block.timestamp % 2 ** 32);
        uint32 lTimeElapsed;
        unchecked {
            lTimeElapsed = lBlockTimestamp - lBlockTimestampLast; // overflow is desired
        }
        if (lTimeElapsed > 0 && aReserve0 != 0 && aReserve1 != 0) {
            _updateOracle(aReserve0, aReserve1, lTimeElapsed, lBlockTimestampLast);
        }

        _slot0.reserve0 = uint104(aBalance0);
        _slot0.reserve1 = uint104(aBalance1);
        _slot0.blockTimestampLast = lBlockTimestamp;

        // TODO: _slot0.{reserve0,reserve1} -> aBalance0,aBalance1 after we have
        //       tests.
        emit Sync(_slot0.reserve0, _slot0.reserve1);
    }
}
