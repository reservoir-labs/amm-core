pragma solidity 0.8.13;

import { stdMath } from "forge-std/Test.sol";

import { IOracleWriter } from "src/interfaces/IOracleWriter.sol";
import { FactoryStoreLib } from "src/libraries/FactoryStore.sol";
import { Bytes32Lib } from "src/libraries/Bytes32.sol";
import { LogCompression } from "src/libraries/LogCompression.sol";
import { Pair } from "src/Pair.sol";
import { GenericFactory } from "src/GenericFactory.sol";

abstract contract OracleWriter is Pair, IOracleWriter {
    using FactoryStoreLib for GenericFactory;
    using Bytes32Lib for bytes32;

    // 10 basis points per second which is 6% per minute and doubling of the price in 16 minutes
    uint256 internal constant MAX_CHANGE_PER_SEC = 0.001e18;

    Observation[65536] public observations;
    uint16 public index = type(uint16).max;

    // maximum allowed rate of change of price per second
    // to mitigate oracle manipulation attacks in the face of post-merge ETH
    uint256 public allowedChangePerSecond;
    uint256 public prevClampedPrice;

    constructor() {
        uint256 lAllowedChangePerSecond = factory.read("Shared::allowedChangePerSecond").toUint256();
        require(0 < lAllowedChangePerSecond && lAllowedChangePerSecond <= MAX_CHANGE_PER_SEC, "OW: INVALID_CHANGE_PER_SECOND");
        allowedChangePerSecond = lAllowedChangePerSecond;
    }

    /**
     * @param _reserve0 in its native precision
     * @param _reserve1 in its native precision
     * @param timeElapsed time since the last oracle observation
     * @param timestampLast the time of the last activity on the pair
     */
    function _updateOracle(uint256 _reserve0, uint256 _reserve1, uint32 timeElapsed, uint32 timestampLast) internal virtual;

    function setAllowedChangePerSecond(uint256 aAllowedChangePerSecond) external onlyFactory {
        require(0 < aAllowedChangePerSecond && aAllowedChangePerSecond <= MAX_CHANGE_PER_SEC, "OW: INVALID_CHANGE_PER_SECOND");
        allowedChangePerSecond = aAllowedChangePerSecond;
    }

    function _calcClampedPrice(
        uint256 aCurrRawPrice, uint256 aPrevClampedPrice, uint256 aTimeElapsed
    ) internal virtual returns (uint256 rClampedPrice, int112 rClampedLogPrice) {
        if (aPrevClampedPrice == 0) {
            return (aCurrRawPrice, int112(LogCompression.toLowResLog(aCurrRawPrice)));
        }

        if (_calcPercentageDiff(aCurrRawPrice, aPrevClampedPrice) > allowedChangePerSecond * aTimeElapsed) {
            // clamp the price
            if (aCurrRawPrice > aPrevClampedPrice) {
                rClampedPrice = aPrevClampedPrice * (1e18 + (allowedChangePerSecond * aTimeElapsed)) / 1e18;
            }
            else {
                assert(aPrevClampedPrice > aCurrRawPrice);
                rClampedPrice = aPrevClampedPrice * (1e18 - (allowedChangePerSecond * aTimeElapsed)) / 1e18;
            }
            rClampedLogPrice = int112(LogCompression.toLowResLog(rClampedPrice));
        }
        else {
            rClampedPrice = aCurrRawPrice;
            rClampedLogPrice = int112(LogCompression.toLowResLog(aCurrRawPrice));
        }
    }

    function _calcPercentageDiff(uint256 a, uint256 b) private pure returns (uint256) {
        return stdMath.percentDelta(a, b);
    }
}
