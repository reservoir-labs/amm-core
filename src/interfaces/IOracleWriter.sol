pragma solidity 0.8.13;

interface IOracleWriter {
    struct Observation {
        // natural log (ln) of the price (token1/token0)
        int112 logAccPrice;
        // natural log (ln) of the liquidity (sqrt(k))
        int112 logAccLiquidity;
        // overflows every 136 years, in the year 2106
        uint32 timestamp;
    }

    function observations(uint256 index) external view returns (int112, int112, uint32);
    function index() external returns (uint16);
}
