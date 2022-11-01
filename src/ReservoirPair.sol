pragma solidity 0.8.13;

import { AssetManagedPair } from "src/asset-management/AssetManagedPair.sol";
import { OracleWriter } from "src/oracle/OracleWriter.sol";
import { ReentrancyGuard } from "solmate/utils/ReentrancyGuard.sol";

abstract contract ReservoirPair is AssetManagedPair, OracleWriter, ReentrancyGuard {
    // force reserves to match balances
    function sync() external nonReentrant {
        _syncManaged();
        _update(_totalToken0(), _totalToken1(), reserve0, reserve1);
    }

    // force balances to match reserves
    function skim(address to) external nonReentrant {
        uint256 _reserve0 = reserve0; // gas savings
        uint256 _reserve1 = reserve1;

        _checkedTransfer(token0, to, _totalToken0() - _reserve0, _reserve0, _reserve1);
        _checkedTransfer(token1, to, _totalToken1() - _reserve1, _reserve0, _reserve1);
    }

    function _checkedTransfer(
        address aToken, address aDestination, uint256 aAmount, uint256 aReserve0, uint256 aReserve1
    ) internal {
        // if transfer fails for whatever reason
        if (!_safeTransfer(aToken, aDestination, aAmount)) {
            uint256 tokenOutManaged = aToken == token0 ? token0Managed : token1Managed;
            uint256 reserveOut = aToken == token0 ? aReserve0 : aReserve1;
            if (reserveOut - tokenOutManaged < aAmount) {
                assetManager.returnAsset(aToken == token0, aAmount - (reserveOut - tokenOutManaged));
                require(_safeTransfer(aToken, aDestination, aAmount), "RP: TRANSFER_FAILED");
            }
            else {
                revert("RP: TRANSFER_FAILED");
            }
        }
    }

    // update reserves and, on the first call per block, price and liq accumulators
    function _update(uint256 balance0, uint256 balance1, uint112 _reserve0, uint112 _reserve1) internal override {
        require(balance0 <= type(uint112).max && balance1 <= type(uint112).max, "CP: OVERFLOW");

        uint32 blockTimestamp = uint32(block.timestamp % 2**32);
        uint32 timeElapsed;
        unchecked {
            timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired
        }
        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            _updateOracle(_reserve0, _reserve1, timeElapsed, blockTimestampLast);
        }

        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        blockTimestampLast = blockTimestamp;
        emit Sync(reserve0, reserve1);
    }

    function setMaxChangePerSecond(uint8 aChangePerSecond) external override onlyFactory {
        require(0 <= aChangePerSecond && aChangePerSecond <= MAX_CHANGE_PER_SEC, "RP: INVALID_CHANGE_PER_SECOND");
        allowedChangePerSecond = aChangePerSecond;
    }
}
