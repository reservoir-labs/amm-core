pragma solidity 0.8.13;

import "src/interfaces/IOracleWriter.sol";

abstract contract OracleWriter is IOracleWriter {
    Observation[65536] public observations;
    uint16 public index = type(uint16).max;

    function _updateOracle(uint112 _reserve0, uint112 _reserve1, uint32 timeElapsed, uint32 timestampLast) internal virtual;
}
