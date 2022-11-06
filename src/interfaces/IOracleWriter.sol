pragma solidity 0.8.13;

interface IOracleWriter {
    struct Observation {
        // natural log (ln) of the raw accumulated price (token1/token0)
        int112 logAccRawPrice;
        // natural log (ln) of the clamped accumulated price (token1/token0)
        // in the case of maximum price supported by the oracle (~2.87e56 == e ** 130.0000)
        // (1300000) 21 bits multiplied by 32 bits of the timestamp gives 53 bits
        // which fits into int56
        int56 logAccClampedPrice;
        // natural log (ln) of the accumulated liquidity (sqrt(x * y))
        // in the case of maximum liq (sqrt(uint112 * uint112) == 5.192e33 == e ** 77.5325)
        // (775325) 20 bits multiplied by 32 bits of the timestamp gives 52 bits
        // which fits into int56
        int56 logAccLiquidity;
        // overflows every 136 years, in the year 2106
        uint32 timestamp;
    }

    function observations(uint256 aIndex) external view returns (
        int112 rlogAccRawPrice,
        int56 rLogAccClampedPrice,
        int56 rLogAccLiquidity,
        uint32 rTimestamp
    );
    function index() external view returns (uint16 rIndex);
    function setAllowedChangePerSecond(uint256 aAllowedChangePerSecond) external;
}
