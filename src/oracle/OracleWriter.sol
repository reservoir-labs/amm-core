pragma solidity ^0.8.0;

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
    uint internal constant MAX_CHANGE_PER_SEC = 0.01e18;
    string internal constant ALLOWED_CHANGE_NAME = "Shared::allowedChangePerSecond";
    string internal constant ORACLE_CALLER_NAME = "Shared::oracleCaller";

    Observation[65_536] internal _observations;
    uint16 public index = type(uint16).max;

    // maximum allowed rate of change of price per second
    // to mitigate oracle manipulation attacks in the face of post-merge ETH
    uint public allowedChangePerSecond;
    uint public prevClampedPrice;

    address public oracleCaller;

    constructor() {
        updateOracleCaller();
        setAllowedChangePerSecond(factory.read(ALLOWED_CHANGE_NAME).toUint256());
    }

    function observation(uint aIndex) external view returns (Observation memory rObservation) {
        require(msg.sender == oracleCaller, "OW: NOT_ORACLE_CALLER");
        rObservation = _observations[aIndex];
    }

    function updateOracleCaller() public {
        address lNewCaller = factory.read(ORACLE_CALLER_NAME).toAddress();
        if (lNewCaller != oracleCaller) {
            emit OracleCallerChanged(oracleCaller, lNewCaller);
            oracleCaller = lNewCaller;
        }
    }

    function setAllowedChangePerSecond(uint aAllowedChangePerSecond) public onlyFactory {
        require(
            0 < aAllowedChangePerSecond && aAllowedChangePerSecond <= MAX_CHANGE_PER_SEC,
            "OW: INVALID_CHANGE_PER_SECOND"
        );
        emit AllowedChangePerSecondChanged(allowedChangePerSecond, aAllowedChangePerSecond);
        allowedChangePerSecond = aAllowedChangePerSecond;
    }

    function _calcClampedPrice(uint aCurrRawPrice, uint aPrevClampedPrice, uint aTimeElapsed)
        internal
        virtual
        returns (uint rClampedPrice, int112 rClampedLogPrice)
    {
        if (aPrevClampedPrice == 0) {
            return (aCurrRawPrice, int112(LogCompression.toLowResLog(aCurrRawPrice)));
        }

        if (_calcPercentageDiff(aCurrRawPrice, aPrevClampedPrice) > allowedChangePerSecond * aTimeElapsed) {
            // clamp the price
            if (aCurrRawPrice > aPrevClampedPrice) {
                rClampedPrice = aPrevClampedPrice * (1e18 + (allowedChangePerSecond * aTimeElapsed)) / 1e18;
            } else {
                assert(aPrevClampedPrice > aCurrRawPrice);
                rClampedPrice = aPrevClampedPrice * (1e18 - (allowedChangePerSecond * aTimeElapsed)) / 1e18;
            }
            rClampedLogPrice = int112(LogCompression.toLowResLog(rClampedPrice));
        } else {
            rClampedPrice = aCurrRawPrice;
            rClampedLogPrice = int112(LogCompression.toLowResLog(aCurrRawPrice));
        }
    }

    function _calcPercentageDiff(uint a, uint b) private pure returns (uint) {
        return stdMath.percentDelta(a, b);
    }

    /**
     * @param _reserve0 in its native precision
     * @param _reserve1 in its native precision
     * @param timeElapsed time since the last oracle observation
     * @param timestampLast the time of the last activity on the pair
     */
    function _updateOracle(uint _reserve0, uint _reserve1, uint32 timeElapsed, uint32 timestampLast) internal virtual;
}
