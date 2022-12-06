pragma solidity ^0.8.0;

import { AssetManagedPair } from "src/asset-management/AssetManagedPair.sol";
import { OracleWriter, Observation } from "src/oracle/OracleWriter.sol";
import { ReentrancyGuard } from "solmate/utils/ReentrancyGuard.sol";

abstract contract ReservoirPair is AssetManagedPair, OracleWriter, ReentrancyGuard {
    /// @notice Force reserves to match balances.
    function sync() external nonReentrant {
        _syncManaged();
        _update(_totalToken0(), _totalToken1(), _reserve0, _reserve1);
    }

    /// @notice Force balances to match reserves.
    function skim(address aTo) external nonReentrant {
        uint256 lReserve0 = _reserve0; // gas savings
        uint256 lReserve1 = _reserve1;

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
    function _update(uint256 aBalance0, uint256 aBalance1, uint112 aReserve0, uint112 aReserve1) internal override {
        require(aBalance0 <= type(uint112).max && aBalance1 <= type(uint112).max, "CP: OVERFLOW");

        uint32 lBlockTimestamp = uint32(block.timestamp % 2 ** 32);
        uint32 lTimeElapsed;
        unchecked {
            lTimeElapsed = lBlockTimestamp - _blockTimestampLast; // overflow is desired
        }
        if (lTimeElapsed > 0 && aReserve0 != 0 && aReserve1 != 0) {
            _updateOracle(aReserve0, aReserve1, lTimeElapsed, _blockTimestampLast);
        }

        _reserve0 = uint112(aBalance0);
        _reserve1 = uint112(aBalance1);
        _blockTimestampLast = lBlockTimestamp;
        // PERF: Does this use SLOADs?
        emit Sync(_reserve0, _reserve1);
    }
}
