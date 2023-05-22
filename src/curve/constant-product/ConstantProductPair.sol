// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import { Math } from "@openzeppelin/utils/math/Math.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";

import { Bytes32Lib } from "src/libraries/Bytes32.sol";
import { FactoryStoreLib } from "src/libraries/FactoryStore.sol";
import { ConstantProductMath } from "src/libraries/ConstantProductMath.sol";
import { ConstantProductOracleMath } from "src/libraries/ConstantProductOracleMath.sol";
import { IReservoirCallee } from "src/interfaces/IReservoirCallee.sol";
import { IGenericFactory, IERC20 } from "src/interfaces/IGenericFactory.sol";

import { ReservoirPair, Slot0, Observation } from "src/ReservoirPair.sol";

contract ConstantProductPair is ReservoirPair {
    using FactoryStoreLib for IGenericFactory;
    using Bytes32Lib for bytes32;

    // Accuracy^2:
    // 10_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000
    uint256 public constant SQUARED_ACCURACY = 1e76;
    // Accuracy: 100_000_000_000_000_000_000_000_000_000_000_000_000
    uint256 public constant ACCURACY = 1e38;

    string private constant PAIR_SWAP_FEE_NAME = "CP::swapFee";

    uint256 public kLast; // reserve0 * reserve1, as of immediately after the most recent liquidity event

    // solhint-disable-next-line no-empty-blocks
    constructor(IERC20 aToken0, IERC20 aToken1) ReservoirPair(aToken0, aToken1, PAIR_SWAP_FEE_NAME, true) {
        // no additional initialization is required as all constructor logic is in ReservoirPair
    }

    /**
     * _calcFee calculates the appropriate platform fee in terms of tokens that will be minted, based on the growth
     * in sqrt(k), the amount of liquidity in the pool, and the set variable fee in basis points.
     *
     * This function implements the equation defined in the Uniswap V2 whitepaper for calculating platform fees, on
     * which their fee calculation implementation is based. This is a refactored form of equation 6, on page 5 of the
     * Uniswap whitepaper; see https://uniswap.org/whitepaper.pdf for further details.
     *
     * The specific difference between the Uniswap V2 implementation and this fee calculation is the fee variable,
     * which remains a variable with range 0-100% here, but is fixed at (1/6)% in Uniswap V2.
     *
     * The mathematical equation:
     * If 'Fee' is the platform fee, and the previous and new values of the square-root of the invariant k, are
     * K1 and K2 respectively; this equation, in the form coded here can be expressed as:
     *
     *   lSharesToIssue = totalSupply * Fee * (1 - K1/K2) / ( 1 - Fee * (1 - K1/K2) )
     *
     * A reader of the whitepaper will note that this equation is not a literally the same as equation (6), however
     * with some straight-forward algebraic manipulation they can be shown to be mathematically equivalent.
     */
    function _calcFee(uint256 aSqrtNewK, uint256 aSqrtOldK, uint256 aPlatformFee, uint256 aCirculatingShares)
        internal
        pure
        returns (uint256 rSharesToIssue)
    {
        // INVARIANT: `aSqrtOldK & aSqrtNewK < uint104` as _syncManaged ensures that both reserves fit into uint104.
        //            The sqrt of the product of the two reserves will fit into uint104 as well
        // INVARIANT: `aSqrtOldK < aSqrtNewK` as checked in _mintFee
        // INVARIANT: `aPlatformFee < FEE_ACCURACY` enforced by setter function
        // INVARIANT: `aCirculatingShares < uint104`  since the circulating shares are the geometric mean of the reserves
        //            and that both reserves fit into uint104 as explained above, aCirculatingShares will fit into uint104 as well
        unchecked {
            uint256 lScaledGrowth = aSqrtNewK * ACCURACY / aSqrtOldK; // ASSERT: < UINT256
            uint256 lScaledMultiplier = ACCURACY - (SQUARED_ACCURACY / lScaledGrowth); // ASSERT: < UINT128
            uint256 lScaledTargetOwnership = lScaledMultiplier * aPlatformFee / FEE_ACCURACY; // ASSERT: < UINT144 during maths, ends < UINT128

            rSharesToIssue = lScaledTargetOwnership * aCirculatingShares / (ACCURACY - lScaledTargetOwnership); // ASSERT: lScaledTargetOwnership < ACCURACY
        }
    }

    function _mintFee(uint256 aReserve0, uint256 aReserve1) private {
        bool lFeeOn = platformFee > 0;

        if (lFeeOn) {
            uint256 lSqrtOldK = FixedPointMathLib.sqrt(kLast); // gas savings

            if (lSqrtOldK != 0) {
                uint256 lSqrtNewK = FixedPointMathLib.sqrt(aReserve0 * aReserve1);

                if (lSqrtNewK > lSqrtOldK) {
                    uint256 lSharesToIssue = _calcFee(lSqrtNewK, lSqrtOldK, platformFee, totalSupply);

                    if (lSharesToIssue > 0) {
                        address platformFeeTo = factory.read(PLATFORM_FEE_TO_NAME).toAddress();
                        _mint(platformFeeTo, lSharesToIssue);
                    }
                }
            }
        }
    }

    function mint(address aTo) external override returns (uint256 rLiquidity) {
        (Slot0 storage sSlot0, uint256 lReserve0, uint256 lReserve1, uint32 lBlockTimestampLast,) = _lockAndLoad();
        (lReserve0, lReserve1) = _syncManaged(uint104(lReserve0), uint104(lReserve1)); // check asset-manager pnl

        uint256 lBalance0 = _totalToken0();
        uint256 lBalance1 = _totalToken1();
        uint256 lAmount0 = lBalance0 - lReserve0;
        uint256 lAmount1 = lBalance1 - lReserve1;

        _mintFee(lReserve0, lReserve1);
        uint256 lTotalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        if (lTotalSupply == 0) {
            rLiquidity = FixedPointMathLib.sqrt(lAmount0 * lAmount1) - MINIMUM_LIQUIDITY;
            _mint(address(0), MINIMUM_LIQUIDITY); // permanently lock the first MINIMUM_LIQUIDITY tokens
        } else {
            // multiplication will not phantom overflow as lTotalSupply is uint104 max
            // lAmount0 has to be <= uint104 for this mint to be valid anyway, else it would revert at _updateAndUnlock
            rLiquidity = Math.min(lAmount0 * lTotalSupply / lReserve0, lAmount1 * lTotalSupply / lReserve1);
        }
        require(rLiquidity > 0, "CP: INSUFFICIENT_LIQ_MINTED");
        _mint(aTo, rLiquidity);

        // NB: The size of lBalance0 & lBalance1 will be verified in _update.
        kLast = lBalance0 * lBalance1;
        emit Mint(msg.sender, lAmount0, lAmount1);

        _updateAndUnlock(sSlot0, lBalance0, lBalance1, lReserve0, lReserve1, lBlockTimestampLast);
        _managerCallback();
    }

    function burn(address aTo) external override returns (uint256 rAmount0, uint256 rAmount1) {
        // NB: Must sync management PNL before we load reserves.
        (Slot0 storage sSlot0, uint256 lReserve0, uint256 lReserve1, uint32 lBlockTimestampLast,) = _lockAndLoad();
        (lReserve0, lReserve1) = _syncManaged(uint104(lReserve0), uint104(lReserve1)); // check asset-manager pnl

        uint256 liquidity = balanceOf[address(this)];

        _mintFee(lReserve0, lReserve1);
        uint256 lTotalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        rAmount0 = liquidity * _totalToken0() / lTotalSupply; // using balances ensures pro-rata distribution
        rAmount1 = liquidity * _totalToken1() / lTotalSupply; // using balances ensures pro-rata distribution
        _burn(address(this), liquidity);

        _checkedTransfer(token0(), aTo, rAmount0, lReserve0, lReserve1);
        _checkedTransfer(token1(), aTo, rAmount1, lReserve0, lReserve1);

        uint256 lBalance0 = _totalToken0();
        uint256 lBalance1 = _totalToken1();

        // NB: The size of lBalance0 & lBalance1 will be verified in _update.
        kLast = lBalance0 * lBalance1;
        emit Burn(msg.sender, rAmount0, rAmount1);

        _updateAndUnlock(sSlot0, lBalance0, lBalance1, lReserve0, lReserve1, lBlockTimestampLast);
        _managerCallback();
    }

    function swap(int256 aAmount, bool aExactIn, address aTo, bytes calldata aData)
        external
        override
        returns (uint256 rAmountOut)
    {
        (Slot0 storage sSlot0, uint256 lReserve0, uint256 lReserve1, uint32 lBlockTimestampLast,) = _lockAndLoad();
        require(aAmount != 0, "CP: AMOUNT_ZERO");
        uint256 lAmountIn;
        IERC20 lTokenOut;

        if (aExactIn) {
            // swap token0 exact in for token1 variable out
            if (aAmount > 0) {
                lTokenOut = token1();
                lAmountIn = uint256(aAmount);
                rAmountOut = ConstantProductMath.getAmountOut(lAmountIn, lReserve0, lReserve1, swapFee);
            }
            // swap token1 exact in for token0 variable out
            else {
                lTokenOut = token0();
                unchecked {
                    lAmountIn = uint256(-aAmount);
                }
                rAmountOut = ConstantProductMath.getAmountOut(lAmountIn, lReserve1, lReserve0, swapFee);
            }
        } else {
            // swap token1 variable in for token0 exact out
            if (aAmount > 0) {
                rAmountOut = uint256(aAmount);
                require(rAmountOut < lReserve0, "CP: NOT_ENOUGH_LIQ");
                lTokenOut = token0();
                lAmountIn = ConstantProductMath.getAmountIn(rAmountOut, lReserve1, lReserve0, swapFee);
            }
            // swap token0 variable in for token1 exact out
            else {
                unchecked {
                    rAmountOut = uint256(-aAmount);
                }
                require(rAmountOut < lReserve1, "CP: NOT_ENOUGH_LIQ");
                lTokenOut = token1();
                lAmountIn = ConstantProductMath.getAmountIn(rAmountOut, lReserve0, lReserve1, swapFee);
            }
        }

        // optimistically transfers tokens
        _checkedTransfer(lTokenOut, aTo, rAmountOut, lReserve0, lReserve1);

        if (aData.length > 0) {
            IReservoirCallee(aTo).reservoirCall(
                msg.sender,
                lTokenOut == token0() ? int256(rAmountOut) : -int256(lAmountIn),
                lTokenOut == token1() ? int256(rAmountOut) : -int256(lAmountIn),
                aData
            );
        }

        uint256 lBalance0 = _totalToken0();
        uint256 lBalance1 = _totalToken1();

        uint256 lReceived = lTokenOut == token0() ? lBalance1 - lReserve1 : lBalance0 - lReserve0;
        require(lAmountIn <= lReceived, "CP: INSUFFICIENT_AMOUNT_IN");

        _updateAndUnlock(sSlot0, lBalance0, lBalance1, lReserve0, lReserve1, lBlockTimestampLast);
        emit Swap(msg.sender, lTokenOut == token1(), lReceived, rAmountOut, aTo);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                ORACLE METHODS
    //////////////////////////////////////////////////////////////////////////*/

    function _updateOracle(uint256 aReserve0, uint256 aReserve1, uint32 aTimeElapsed, uint32 aTimestampLast)
        internal
        override
    {
        Observation storage previous = _observations[_slot0.index];

        (uint256 lCurrRawPrice, int112 currLogRawPrice) = ConstantProductOracleMath.calcLogPrice(
            aReserve0 * token0PrecisionMultiplier(), aReserve1 * token1PrecisionMultiplier()
        );
        (uint256 lCurrClampedPrice, int112 currLogClampedPrice) =
            _calcClampedPrice(lCurrRawPrice, prevClampedPrice, aTimeElapsed);
        int112 lCurrLogLiq = ConstantProductOracleMath.calcLogLiq(aReserve0, aReserve1);
        prevClampedPrice = lCurrClampedPrice;

        // overflow is desired here as the consumer of the oracle will be reading the difference in those
        // accumulated log values
        // when the index overflows it will overwrite the oldest observation and then forms a loop
        unchecked {
            int112 logAccRawPrice = previous.logAccRawPrice + currLogRawPrice * int112(int256(uint256(aTimeElapsed)));
            int56 logAccClampedPrice =
                previous.logAccClampedPrice + int56(currLogClampedPrice) * int56(int256(uint256(aTimeElapsed)));
            int56 logAccLiq = previous.logAccLiquidity + int56(lCurrLogLiq) * int56(int256(uint256(aTimeElapsed)));
            _slot0.index += 1;
            _observations[_slot0.index] = Observation(logAccRawPrice, logAccClampedPrice, logAccLiq, aTimestampLast);
        }
    }
}
