pragma solidity 0.8.13;

import { stdMath } from "forge-std/Test.sol";

import { IOracleWriter, Observation } from "src/interfaces/IOracleWriter.sol";
import { FactoryStoreLib } from "src/libraries/FactoryStore.sol";
import { Bytes32Lib } from "src/libraries/Bytes32.sol";
import { LogCompression } from "src/libraries/LogCompression.sol";
import { Pair } from "src/Pair.sol";
import { GenericFactory } from "src/GenericFactory.sol";

abstract contract OracleWriter is Pair, IOracleWriter {
    using FactoryStoreLib for GenericFactory;
    using Bytes32Lib for bytes32;

    // 100 basis points per second which is 60% per minute
    uint256 internal constant MAX_CHANGE_PER_SEC = 0.01e18;
    string internal constant ALLOWED_CHANGE_NAME = "Shared::allowedChangePerSecond";
    string internal constant ORACLE_CALLER_NAME = "Shared::oracleCaller";

    Observation[65536] public _observations;
    uint16 public index = type(uint16).max;

    // maximum allowed rate of change of price per second
    // to mitigate oracle manipulation attacks in the face of post-merge ETH
    uint256 public allowedChangePerSecond;
    uint256 public prevClampedPrice;

    address public oracleCaller;

    modifier onlyOracleCaller() {
        require(msg.sender == oracleCaller, "OW: NOT_ORACLE_CALLER");
        _;
    }

    constructor() {
        setOracleCaller(factory.read(ORACLE_CALLER_NAME).toAddress());
        setAllowedChangePerSecond(factory.read(ALLOWED_CHANGE_NAME).toUint256());
    }

    function observation(uint256 aIndex) external view onlyOracleCaller returns (Observation memory rObservation) {
        rObservation = _observations[aIndex];
    }

    function setOracleCaller(address aNewCaller) public onlyFactory {
        emit OracleCallerChanged(oracleCaller, aNewCaller);
        oracleCaller = aNewCaller;
    }

    function setAllowedChangePerSecond(uint256 aAllowedChangePerSecond) public onlyFactory {
        require(0 < aAllowedChangePerSecond && aAllowedChangePerSecond <= MAX_CHANGE_PER_SEC, "OW: INVALID_CHANGE_PER_SECOND");
        emit AllowedChangePerSecondChanged(allowedChangePerSecond, aAllowedChangePerSecond);
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

    /**
     * @param _reserve0 in its native precision
     * @param _reserve1 in its native precision
     * @param timeElapsed time since the last oracle observation
     * @param timestampLast the time of the last activity on the pair
     */
    function _updateOracle(uint256 _reserve0, uint256 _reserve1, uint32 timeElapsed, uint32 timestampLast) internal virtual;
}
