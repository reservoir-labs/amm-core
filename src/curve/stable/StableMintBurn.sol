// TODO: Can we reduce the nesting by deleting the parent dir?
// TODO: License
// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import { Math } from "@openzeppelin/utils/math/Math.sol";

import { Bytes32Lib } from "src/libraries/Bytes32.sol";
import { FactoryStoreLib } from "src/libraries/FactoryStore.sol";

import { GenericFactory } from "src/GenericFactory.sol";

import { IReservoirCallee } from "src/interfaces/IReservoirCallee.sol";
import { StableMath } from "src/libraries/StableMath.sol";
import { StableOracleMath } from "src/libraries/StableOracleMath.sol";
import { ReservoirPair, Observation } from "src/ReservoirPair.sol";
import { IPair, Pair } from "src/Pair.sol";

struct AmplificationData {
    /// @dev initialA is stored with A_PRECISION (i.e. multiplied by 100)
    uint64 initialA;
    /// @dev futureA is stored with A_PRECISION (i.e. multiplied by 100)
    uint64 futureA;
    /// @dev initialATime is a unix timestamp and will only overflow every 584 billion years
    uint64 initialATime;
    /// @dev futureATime is a unix timestamp and will only overflow every 584 billion years
    uint64 futureATime;
}

contract StableMintBurn is ReservoirPair {
    using FactoryStoreLib for GenericFactory;
    using Bytes32Lib for bytes32;

    string private constant PAIR_SWAP_FEE_NAME = "SP::swapFee";
    string private constant AMPLIFICATION_COEFFICIENT_NAME = "SP::amplificationCoefficient";

    AmplificationData public ampData;

    uint256 private _locked = 1;

    // We need the 2 variables below to calculate the growth in liquidity between
    // minting and burning, for the purpose of calculating platformFee.
    uint192 private lastInvariant;
    uint64 private lastInvariantAmp;

    constructor(address aToken0, address aToken1) Pair(aToken0, aToken1, PAIR_SWAP_FEE_NAME) {
        ampData.initialA = factory.read(AMPLIFICATION_COEFFICIENT_NAME).toUint64() * uint64(StableMath.A_PRECISION);
        ampData.futureA = ampData.initialA;
        ampData.initialATime = uint64(block.timestamp);
        ampData.futureATime = uint64(block.timestamp);

        require(
            ampData.initialA >= StableMath.MIN_A * uint64(StableMath.A_PRECISION)
                && ampData.initialA <= StableMath.MAX_A * uint64(StableMath.A_PRECISION),
            "SP: INVALID_A"
        );
    }

    /// @dev This fee is charged to cover for `swapFee` when users add unbalanced liquidity.
    function _nonOptimalMintFee(uint256 _amount0, uint256 _amount1, uint256 lReserve0, uint256 lReserve1)
        internal
        view
        returns (uint256 token0Fee, uint256 token1Fee)
    {
        if (lReserve0 == 0 || lReserve1 == 0) return (0, 0);
        uint256 amount1Optimal = (_amount0 * lReserve1) / lReserve0;

        if (amount1Optimal <= _amount1) {
            token1Fee = (swapFee * (_amount1 - amount1Optimal)) / (2 * FEE_ACCURACY);
        } else {
            uint256 amount0Optimal = (_amount1 * lReserve0) / lReserve1;
            token0Fee = (swapFee * (_amount0 - amount0Optimal)) / (2 * FEE_ACCURACY);
        }
        require(token0Fee <= type(uint104).max && token1Fee <= type(uint104).max, "SP: NON_OPTIMAL_FEE_TOO_LARGE");
    }

    /// @dev Mints LP tokens - should be called via the router after transferring tokens.
    /// The router must ensure that sufficient LP tokens are minted by using the return value.
    function mint(address aTo) external returns (uint256 rLiquidity) {
        // NB: Must sync management PNL before we load reserves.
        // TODO: Is passing/using reserves as uint256 cheaper and still safe?
        (uint104 lReserve0, uint104 lReserve1, uint32 lBlockTimestampLast,) = _lockAndLoad();
        (lReserve0, lReserve1) = _syncManaged(lReserve0, lReserve1);

        (uint256 lBalance0, uint256 lBalance1) = _balances();

        uint256 lNewLiq = _computeLiquidity(lBalance0, lBalance1);
        uint256 lAmount0 = lBalance0 - lReserve0;
        uint256 lAmount1 = lBalance1 - lReserve1;

        (uint256 lFee0, uint256 lFee1) = _nonOptimalMintFee(lAmount0, lAmount1, lReserve0, lReserve1);
        lReserve0 += uint104(lFee0);
        lReserve1 += uint104(lFee1);

        (uint256 lTotalSupply, uint256 lOldLiq) = _mintFee(lReserve0, lReserve1);

        if (lTotalSupply == 0) {
            require(lAmount0 > 0 && lAmount1 > 0, "SP: INVALID_AMOUNTS");
            rLiquidity = lNewLiq - MINIMUM_LIQUIDITY;
            _mint(address(0), MINIMUM_LIQUIDITY);
        } else {
            rLiquidity = ((lNewLiq - lOldLiq) * lTotalSupply) / lOldLiq;
        }
        require(rLiquidity != 0, "SP: INSUFFICIENT_LIQ_MINTED");
        _mint(aTo, rLiquidity);

        // casting is safe as the max invariant would be 2 * uint104 * uint60 (in the case of tokens with 0 decimal
        // places)
        // which results in 112 + 60 + 1 = 173 bits
        // which fits into uint192
        lastInvariant = uint192(lNewLiq);
        lastInvariantAmp = _getCurrentAPrecise();

        emit Mint(msg.sender, lAmount0, lAmount1);

        _updateAndUnlock(lBalance0, lBalance1, lReserve0, lReserve1, lBlockTimestampLast);
        _managerCallback();
    }

    /// @dev Burns LP tokens sent to this contract. The router must ensure that the user gets sufficient output tokens.
    function burn(address aTo) external returns (uint256 amount0, uint256 amount1) {
        // NB: Must sync management PNL before we load reserves.
        (uint104 lReserve0, uint104 lReserve1, uint32 lBlockTimestampLast,) = _lockAndLoad();
        (lReserve0, lReserve1) = _syncManaged(lReserve0, lReserve1);

        uint256 liquidity = balanceOf[address(this)];

        (uint256 lTotalSupply,) = _mintFee(lReserve0, lReserve1);

        amount0 = (liquidity * lReserve0) / lTotalSupply;
        amount1 = (liquidity * lReserve1) / lTotalSupply;

        _burn(address(this), liquidity);

        _checkedTransfer(token0, aTo, amount0, lReserve0, lReserve1);
        _checkedTransfer(token1, aTo, amount1, lReserve0, lReserve1);

        uint256 lBalance0 = _totalToken0();
        uint256 lBalance1 = _totalToken1();
        lastInvariant = uint192(_computeLiquidity(lBalance0, lBalance1));
        lastInvariantAmp = _getCurrentAPrecise();
        emit Burn(msg.sender, amount0, amount1);

        _updateAndUnlock(lBalance0, lBalance1, lReserve0, lReserve1, lBlockTimestampLast);
        _managerCallback();
    }

    /// @inheritdoc IPair
    function swap(int256, bool, address, bytes calldata) external pure returns (uint256) {
        revert("SMB: IMPOSSIBLE");
    }

    function _balances() internal view returns (uint256 rBalance0, uint256 rBalance1) {
        rBalance0 = _totalToken0();
        rBalance1 = _totalToken1();
    }

    /// @notice Get D, the StableSwap invariant, based on a set of balances and a particular A.
    /// See the StableSwap paper for details.
    /// @dev Originally
    /// https://github.com/saddle-finance/saddle-contract/blob/0b76f7fb519e34b878aa1d58cffc8d8dc0572c12/contracts/SwapUtils.sol#L319.
    /// @return rLiquidity The invariant, at the precision of the pool.
    function _computeLiquidity(uint256 aReserve0, uint256 aReserve1) internal view returns (uint256 rLiquidity) {
        unchecked {
            uint256 lAdjustedReserve0 = aReserve0 * token0PrecisionMultiplier;
            uint256 lAdjustedReserve1 = aReserve1 * token1PrecisionMultiplier;
            rLiquidity =
                StableMath._computeLiquidityFromAdjustedBalances(lAdjustedReserve0, lAdjustedReserve1, _getNA());
        }
    }

    function _mintFee(uint256 aReserve0, uint256 aReserve1)
        internal
        returns (uint256 rTotalSupply, uint256 rD)
    {
        bool lFeeOn = platformFee > 0;
        rTotalSupply = totalSupply;
        rD = StableMath._computeLiquidityFromAdjustedBalances(
            aReserve0 * token0PrecisionMultiplier, aReserve1 * token1PrecisionMultiplier, 2 * lastInvariantAmp
        );
        if (lFeeOn) {
            uint256 lDLast = lastInvariant;
            if (lDLast != 0) {
                if (rD > lDLast) {
                    // @dev `platformFee` % of increase in liquidity.
                    uint256 lPlatformFee = platformFee;
                    uint256 lNumerator = rTotalSupply * (rD - lDLast) * lPlatformFee;
                    uint256 lDenominator = (FEE_ACCURACY - lPlatformFee) * rD + lPlatformFee * lDLast;
                    uint256 lPlatformShares = lNumerator / lDenominator;

                    if (lPlatformShares != 0) {
                        address lPlatformFeeTo = factory.read(PLATFORM_FEE_TO_NAME).toAddress();

                        _mint(lPlatformFeeTo, lPlatformShares);
                        rTotalSupply += lPlatformShares;
                    }
                }
            }
        } else if (lastInvariant != 0) {
            lastInvariant = 0;
        }
    }

    function _getCurrentAPrecise() internal view returns (uint64 rCurrentA) {
        uint64 futureA = ampData.futureA;
        uint64 futureATime = ampData.futureATime;

        if (block.timestamp < futureATime) {
            uint64 initialA = ampData.initialA;
            uint64 initialATime = ampData.initialATime;
            uint64 rampDuration = futureATime - initialATime;
            uint64 rampElapsed = uint64(block.timestamp) - initialATime;

            if (futureA > initialA) {
                uint64 rampDelta = futureA - initialA;
                rCurrentA = initialA + rampElapsed * rampDelta / rampDuration;
            } else {
                uint64 rampDelta = initialA - futureA;
                rCurrentA = initialA - rampElapsed * rampDelta / rampDuration;
            }
        } else {
            rCurrentA = futureA;
        }
    }

    /// @dev number of coins in the pool multiplied by A precise
    // perf: is it possible to optimize/simplify by hardcoding to two assets instead of using _getNA() etc
    function _getNA() internal view returns (uint256) {
        return 2 * _getCurrentAPrecise();
    }

    /*//////////////////////////////////////////////////////////////////////////
                                ORACLE METHODS
    //////////////////////////////////////////////////////////////////////////*/

    function _updateOracle(uint256 lReserve0, uint256 lReserve1, uint32 timeElapsed, uint32 timestampLast)
        internal
        override
    {
        Observation storage previous = _observations[_slot0.index];

        (uint256 currRawPrice, int112 currLogRawPrice) = StableOracleMath.calcLogPrice(
            _getCurrentAPrecise(), lReserve0 * token0PrecisionMultiplier, lReserve1 * token1PrecisionMultiplier
        );
        // perf: see if we can avoid using prevClampedPrice and read the two previous oracle observations
        // to figure out the previous clamped price
        (uint256 currClampedPrice, int112 currLogClampedPrice) =
            _calcClampedPrice(currRawPrice, prevClampedPrice, timeElapsed);
        int112 currLogLiq = StableOracleMath.calcLogLiq(lReserve0, lReserve1);
        prevClampedPrice = currClampedPrice;

        unchecked {
            int112 logAccRawPrice = previous.logAccRawPrice + currLogRawPrice * int112(int256(uint256(timeElapsed)));
            int56 logAccClampedPrice =
                previous.logAccClampedPrice + int56(currLogClampedPrice) * int56(int256(uint256(timeElapsed)));
            int56 logAccLiq = previous.logAccLiquidity + int56(currLogLiq) * int56(int256(uint256(timeElapsed)));
            _slot0.index += 1;
            _observations[_slot0.index] = Observation(logAccRawPrice, logAccClampedPrice, logAccLiq, timestampLast);
        }
    }
}
