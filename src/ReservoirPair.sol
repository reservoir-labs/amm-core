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

    // todo: may want to implement _update() in this class
}