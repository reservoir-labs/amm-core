pragma solidity 0.8.13;

interface IOracleWriter {
    struct Observation {
        // natural log (ln) of the raw accumulated price (token1/token0)
        int112 logAccRawPrice;
        // natural log (ln) of the clamped accumulated price (token1/token0)
        // even in the case of extreme prices (3e75), will overflow once every 878 years
        int56 logAccClampedPrice;
        // natural log (ln) of the accumulated liquidity (sqrt(k))
        // even in the case of extreme liquidity (3e75), will overflow once every 878 years
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
