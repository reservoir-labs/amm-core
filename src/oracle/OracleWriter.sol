pragma solidity 0.8.13;

import "src/interfaces/IOracleWriter.sol";

abstract contract OracleWriter is IOracleWriter {
    Observation[65536] public observations;
    uint16 public index = type(uint16).max;

    /**
     * @param _reserve0 already normalized to 18 decimals
     * @param _reserve1 already normalized to 18 decimals
     * @param timeElapsed time since the last oracle observation
     * @param timestampLast the time of the last activity on the pair
     */
    function _updateOracle(uint256 _reserve0, uint256 _reserve1, uint32 timeElapsed, uint32 timestampLast) internal virtual;
}
