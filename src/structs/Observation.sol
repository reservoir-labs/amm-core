// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

struct Observation {
    // natural log (ln) of the raw instant price
    int56 logInstantRawPrice;
    // natural log (ln) of the clamped instant price
    int56 logInstantClampedPrice;

    // natural log (ln) of the raw accumulated price (token1/token0)
    int56 logAccRawPrice;
    // natural log (ln) of the clamped accumulated price (token1/token0)
    // in the case of maximum price supported by the oracle (~2.87e56 == e ** 130.0000)
    // (1300000) 21 bits multiplied by 32 bits of the timestamp gives 53 bits
    // which fits into int56
    int56 logAccClampedPrice;

    // overflows every 136 years, in the year 2106
    uint32 timestamp;
}
