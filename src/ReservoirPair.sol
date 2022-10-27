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

        _returnAndTransfer(token0, to, _totalToken0() - _reserve0, _reserve0, _reserve1);
        _returnAndTransfer(token1, to, _totalToken1() - _reserve1, _reserve0, _reserve1);
    }

    function _returnAndTransfer(
        address aToken, address aDestination, uint256 aAmount, uint256 aReserve0, uint256 aReserve1
    ) internal {
        // if transfer fails for whatever reason
        if (!_safeTransfer(aToken, aDestination, aAmount)) {
            uint256 tokenOutManaged = aToken == token0 ? token0Managed : token1Managed;
            uint256 reserveOut = aToken == token0 ? aReserve0 : aReserve1;
            if (reserveOut - tokenOutManaged < aAmount) {
                assetManager.returnAsset(aToken, aAmount - (reserveOut - tokenOutManaged));
                require(_safeTransfer(aToken, aDestination, aAmount), "RP: TRANSFER_FAILED");
            }
            else {
                revert("RP: TRANSFER_FAILED");
            }
        }
    }

    // todo: may want to implement _update() in this class
}
