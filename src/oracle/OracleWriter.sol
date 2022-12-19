pragma solidity ^0.8.0;

import { stdMath } from "forge-std/Test.sol";

import { FactoryStoreLib } from "src/libraries/FactoryStore.sol";
import { Bytes32Lib } from "src/libraries/Bytes32.sol";
import { LogCompression } from "src/libraries/LogCompression.sol";
import { Pair } from "src/Pair.sol";
import { GenericFactory } from "src/GenericFactory.sol";

struct Observation {
    // natural log (ln) of the raw accumulated price (token1/token0)
    int112 logAccRawPrice;
    // natural log (ln) of the clamped accumulated price (token1/token0)
    // in the case of maximum price supported by the oracle (~2.87e56 == e ** 130.0000)
    // (1300000) 21 bits multiplied by 32 bits of the timestamp gives 53 bits
    // which fits into int56
    int56 logAccClampedPrice;
    // natural log (ln) of the accumulated liquidity (sqrt(x * y))
    // in the case of maximum liq (sqrt(uint104 * uint104) == 5.192e33 == e ** 77.5325)
    // (775325) 20 bits multiplied by 32 bits of the timestamp gives 52 bits
    // which fits into int56
    int56 logAccLiquidity;
    // overflows every 136 years, in the year 2106
    uint32 timestamp;
}

abstract contract OracleWriter is Pair {
    using FactoryStoreLib for GenericFactory;
    using Bytes32Lib for bytes32;

    // TODO: OracleCallerChanged -> OracleCallerUpdated
    event OracleCallerChanged(address oldCaller, address newCaller);
    // TODO: AllowedChangePerSecondChanged -> MaxChangeRateUpdated
    event AllowedChangePerSecondChanged(uint256 oldAllowedChangePerSecond, uint256 newAllowedChangePerSecond);

    // 100 basis points per second which is 60% per minute
    uint256 internal constant MAX_CHANGE_PER_SEC = 0.01e18;
    string internal constant ALLOWED_CHANGE_NAME = "Shared::allowedChangePerSecond";
    string internal constant ORACLE_CALLER_NAME = "Shared::oracleCaller";

    Observation[65_536] internal _observations;

    // maximum allowed rate of change of price per second
    // to mitigate oracle manipulation attacks in the face of post-merge ETH
    // TODO: allowedChangePerSecond -> maxChangeRate
    uint256 public allowedChangePerSecond;
    // TODO: setAllowedChangePerSecond -> setMaxChangeRate
    uint256 public prevClampedPrice;

    address public oracleCaller;

    constructor() {
        updateOracleCaller();
        setAllowedChangePerSecond(factory.read(ALLOWED_CHANGE_NAME).toUint256());
    }

    function observation(uint256 aIndex) external view returns (Observation memory rObservation) {
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

    function setAllowedChangePerSecond(uint256 aAllowedChangePerSecond) public onlyFactory {
        require(
            0 < aAllowedChangePerSecond && aAllowedChangePerSecond <= MAX_CHANGE_PER_SEC,
            "OW: INVALID_CHANGE_PER_SECOND"
        );
        emit AllowedChangePerSecondChanged(allowedChangePerSecond, aAllowedChangePerSecond);
        allowedChangePerSecond = aAllowedChangePerSecond;
    }

    function _calcClampedPrice(uint256 aCurrRawPrice, uint256 aPrevClampedPrice, uint256 aTimeElapsed)
        internal
        virtual
        returns (uint256 rClampedPrice, int112 rClampedLogPrice)
    {
        if (aPrevClampedPrice == 0) {
            return (aCurrRawPrice, int112(LogCompression.toLowResLog(aCurrRawPrice)));
        }

        if (stdMath.percentDelta(aCurrRawPrice, aPrevClampedPrice) > allowedChangePerSecond * aTimeElapsed) {
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

    function _updateOracle(uint256 aReserve0, uint256 aReserve1, uint32 aTimeElapsed, uint32 aTimestampLast)
        internal
        virtual;
}
