// TODO: License
// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import { Math } from "@openzeppelin/utils/math/Math.sol";
import { ERC20 } from "solmate/tokens/ERC20.sol";

import { IReservoirCallee } from "src/interfaces/IReservoirCallee.sol";

import { Bytes32Lib } from "src/libraries/Bytes32.sol";
import { Create2Lib } from "src/libraries/Create2Lib.sol";
import { FactoryStoreLib } from "src/libraries/FactoryStore.sol";

import { GenericFactory } from "src/GenericFactory.sol";
import { ReservoirPair, Observation } from "src/ReservoirPair.sol";
import { StableMintBurn } from "src/curve/stable/StableMintBurn.sol";
import { StableMath } from "src/libraries/StableMath.sol";
import { ConstantsLib } from "src/libraries/Constants.sol";
import { StableOracleMath } from "src/libraries/StableOracleMath.sol";

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

contract StablePair is ReservoirPair {
    using FactoryStoreLib for GenericFactory;
    using Bytes32Lib for bytes32;

    // solhint-disable-next-line var-name-mixedcase
    address private immutable MINT_BURN_LOGIC;

    string private constant PAIR_SWAP_FEE_NAME = "SP::swapFee";
    string private constant AMPLIFICATION_COEFFICIENT_NAME = "SP::amplificationCoefficient";

    event RampA(uint64 initialAPrecise, uint64 futureAPrecise, uint64 initialTime, uint64 futureTme);
    event StopRampA(uint64 currentAPrecise, uint64 time);

    AmplificationData public ampData;

    uint256 private _locked = 1;

    // We need the 2 variables below to calculate the growth in liquidity between
    // minting and burning, for the purpose of calculating platformFee.
    uint192 private lastInvariant;
    uint64 private lastInvariantAmp;

    constructor(address aToken0, address aToken1) ReservoirPair(aToken0, aToken1, PAIR_SWAP_FEE_NAME) {
        MINT_BURN_LOGIC = factory.deploy(ConstantsLib.MINT_BURN_KEY, aToken0, aToken1);
        require(MINT_BURN_LOGIC != address(0), "SP: MINT_BURN_DEPLOYMENT_FAILED");

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

    function rampA(uint64 aFutureARaw, uint64 aFutureATime) external onlyFactory {
        require(aFutureARaw >= StableMath.MIN_A && aFutureARaw <= StableMath.MAX_A, "SP: INVALID_A");

        uint64 lFutureAPrecise = aFutureARaw * uint64(StableMath.A_PRECISION);

        uint256 duration = aFutureATime - block.timestamp;
        require(duration >= StableMath.MIN_RAMP_TIME, "SP: INVALID_DURATION");

        uint64 lCurrentAPrecise = _getCurrentAPrecise();

        // daily rate = (futureA / currentA) / duration * 1 day
        // we do multiplication first before division to avoid
        // losing precision
        uint256 dailyRate = lFutureAPrecise > lCurrentAPrecise
            ? Math.ceilDiv(lFutureAPrecise * 1 days, lCurrentAPrecise * duration)
            : Math.ceilDiv(lCurrentAPrecise * 1 days, lFutureAPrecise * duration);
        require(dailyRate <= StableMath.MAX_AMP_UPDATE_DAILY_RATE, "SP: AMP_RATE_TOO_HIGH");

        ampData.initialA = lCurrentAPrecise;
        ampData.futureA = lFutureAPrecise;
        ampData.initialATime = uint64(block.timestamp);
        ampData.futureATime = aFutureATime;

        emit RampA(lCurrentAPrecise, lFutureAPrecise, uint64(block.timestamp), aFutureATime);
    }

    function stopRampA() external onlyFactory {
        uint64 lCurrentAPrecise = _getCurrentAPrecise();

        ampData.initialA = lCurrentAPrecise;
        ampData.futureA = lCurrentAPrecise;
        uint64 lTimestamp = uint64(block.timestamp);
        ampData.initialATime = lTimestamp;
        ampData.futureATime = lTimestamp;

        emit StopRampA(lCurrentAPrecise, lTimestamp);
    }

    // TODO: Should we use fallback?
    function mint(address) external override returns (uint256) {
        // DELEGATE TO StableMintBurn
        address lTarget = MINT_BURN_LOGIC;
        assembly {
            calldatacopy(0, 0, calldatasize())
            let success := delegatecall(gas(), lTarget, 0, calldatasize(), 0, 0)

            if success {
                returndatacopy(0, 0, returndatasize())
                return(0, returndatasize())
            }

            returndatacopy(0, 0, returndatasize())
            revert(0, returndatasize())
        }
    }

    // TODO: Should we use fallback?
    function burn(address) external override returns (uint256, uint256) {
        // DELEGATE TO StableMintBurn
        address lTarget = MINT_BURN_LOGIC;
        assembly {
            calldatacopy(0, 0, calldatasize())
            let success := delegatecall(gas(), lTarget, 0, calldatasize(), 0, 0)

            if success {
                returndatacopy(0, 0, returndatasize())
                return(0, returndatasize())
            }

            returndatacopy(0, 0, returndatasize())
            revert(0, returndatasize())
        }
    }

    function swap(int256 amount, bool inOrOut, address to, bytes calldata data)
        external
        override
        returns (uint256 amountOut)
    {
        (uint104 lReserve0, uint104 lReserve1, uint32 lBlockTimestampLast,) = _lockAndLoad();
        require(amount != 0, "SP: AMOUNT_ZERO");
        uint256 amountIn;
        ERC20 tokenOut;

        // exact in
        if (inOrOut) {
            // swap token0 exact in for token1 variable out
            if (amount > 0) {
                tokenOut = token1;
                amountIn = uint256(amount);
                amountOut = _getAmountOut(amountIn, lReserve0, lReserve1, true);
            }
            // swap token1 exact in for token0 variable out
            else {
                tokenOut = token0;
                amountIn = uint256(-amount);
                amountOut = _getAmountOut(amountIn, lReserve0, lReserve1, false);
            }
        }
        // exact out
        else {
            // swap token1 variable in for token0 exact out
            if (amount > 0) {
                amountOut = uint256(amount);
                require(amountOut < lReserve0, "SP: NOT_ENOUGH_LIQ");
                tokenOut = token0;
                amountIn = _getAmountIn(amountOut, lReserve0, lReserve1, true);
            }
            // swap token0 variable in for token1 exact out
            else {
                amountOut = uint256(-amount);
                require(amountOut < lReserve1, "SP: NOT_ENOUGH_LIQ");
                tokenOut = token1;
                amountIn = _getAmountIn(amountOut, lReserve0, lReserve1, false);
            }
        }

        _checkedTransfer(tokenOut, to, amountOut, lReserve0, lReserve1);

        if (data.length > 0) {
            IReservoirCallee(to).reservoirCall(
                msg.sender,
                tokenOut == token0 ? int256(amountOut) : -int256(amountIn),
                tokenOut == token1 ? int256(amountOut) : -int256(amountIn),
                data
            );
        }

        uint256 lBalance0 = _totalToken0();
        uint256 lBalance1 = _totalToken1();

        uint256 lReceived = tokenOut == token0 ? lBalance1 - lReserve1 : lBalance0 - lReserve0;
        require(lReceived >= amountIn, "SP: INSUFFICIENT_AMOUNT_IN");

        _updateAndUnlock(lBalance0, lBalance1, lReserve0, lReserve1, lBlockTimestampLast);
        emit Swap(msg.sender, tokenOut == token1, lReceived, amountOut, to);
    }

    function _getAmountOut(uint256 amountIn, uint256 lReserve0, uint256 lReserve1, bool token0In)
        internal
        view
        returns (uint256)
    {
        return StableMath._getAmountOut(
            amountIn,
            lReserve0,
            lReserve1,
            token0PrecisionMultiplier,
            token1PrecisionMultiplier,
            token0In,
            swapFee,
            _getNA()
        );
    }

    function _getAmountIn(uint256 amountOut, uint256 lReserve0, uint256 lReserve1, bool token0Out)
        internal
        view
        returns (uint256)
    {
        return StableMath._getAmountIn(
            amountOut,
            lReserve0,
            lReserve1,
            token0PrecisionMultiplier,
            token1PrecisionMultiplier,
            token0Out,
            swapFee,
            _getNA()
        );
    }

    /// @notice Get D, the StableSwap invariant, based on a set of balances and a particular A.
    /// See the StableSwap paper for details.
    /// @dev Originally
    /// https://github.com/saddle-finance/saddle-contract/blob/0b76f7fb519e34b878aa1d58cffc8d8dc0572c12/contracts/SwapUtils.sol#L319.
    /// @return liquidity The invariant, at the precision of the pool.
    function _computeLiquidity(uint256 lReserve0, uint256 lReserve1) internal view returns (uint256 liquidity) {
        unchecked {
            uint256 adjustedReserve0 = lReserve0 * token0PrecisionMultiplier;
            uint256 adjustedReserve1 = lReserve1 * token1PrecisionMultiplier;
            liquidity = StableMath._computeLiquidityFromAdjustedBalances(adjustedReserve0, adjustedReserve1, _getNA());
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

    function getCurrentA() external view returns (uint64) {
        return _getCurrentAPrecise() / uint64(StableMath.A_PRECISION);
    }

    function getCurrentAPrecise() external view returns (uint64) {
        return _getCurrentAPrecise();
    }

    /*//////////////////////////////////////////////////////////////////////////
                                ORACLE METHODS
    //////////////////////////////////////////////////////////////////////////*/

    function _updateOracle(uint256 aReserve0, uint256 aReserve1, uint32 aTimeElapsed, uint32 aTimestampLast)
        internal
        override
    {
        Observation storage previous = _observations[_slot0.index];

        (uint256 currRawPrice, int112 currLogRawPrice) = StableOracleMath.calcLogPrice(
            _getCurrentAPrecise(), aReserve0 * token0PrecisionMultiplier, aReserve1 * token1PrecisionMultiplier
        );
        // perf: see if we can avoid using prevClampedPrice and read the two previous oracle observations
        // to figure out the previous clamped price
        (uint256 currClampedPrice, int112 currLogClampedPrice) =
            _calcClampedPrice(currRawPrice, prevClampedPrice, aTimeElapsed);
        int112 currLogLiq = StableOracleMath.calcLogLiq(aReserve0, aReserve1);
        prevClampedPrice = currClampedPrice;

        unchecked {
            int112 logAccRawPrice = previous.logAccRawPrice + currLogRawPrice * int112(int256(uint256(aTimeElapsed)));
            int56 logAccClampedPrice =
                previous.logAccClampedPrice + int56(currLogClampedPrice) * int56(int256(uint256(aTimeElapsed)));
            int56 logAccLiq = previous.logAccLiquidity + int56(currLogLiq) * int56(int256(uint256(aTimeElapsed)));
            _slot0.index += 1;
            _observations[_slot0.index] = Observation(logAccRawPrice, logAccClampedPrice, logAccLiq, aTimestampLast);
        }
    }
}
