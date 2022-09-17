pragma solidity 0.8.13;

import "src/interfaces/IAssetManagedPair.sol";
import "src/interfaces/IOracleWriter.sol";

// solhint-disable-next-line no-empty-blocks
interface IReservoirPair is IAssetManagedPair, IOracleWriter {}