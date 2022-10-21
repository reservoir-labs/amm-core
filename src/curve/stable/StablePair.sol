// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import { ERC20 } from "@openzeppelin/token/ERC20/ERC20.sol";
import { Math } from "@openzeppelin/utils/math/Math.sol";

import { Bytes32Lib } from "src/libraries/Bytes32.sol";
import { FactoryStoreLib } from "src/libraries/FactoryStore.sol";

import { GenericFactory } from "src/GenericFactory.sol";

import { IReservoirCallee } from "src/interfaces/IReservoirCallee.sol";
import { StableMath } from "src/libraries/StableMath.sol";
import { StableOracleMath } from "src/libraries/StableOracleMath.sol";
import { ReservoirPair } from "src/ReservoirPair.sol";
import { IPair, Pair } from "src/Pair.sol";

struct AmplificationData {
    /// @dev initialA is stored with A_PRECISION (i.e. multiplied by 100)
    uint64 initialA;
    /// @dev futureA is stored with A_PRECISION (i.e. multiplied by 100)
    uint64 futureA;
    /// @dev initialATime is a unix timestamp and will only overflow in the year 2554
    uint64 initialATime;
    /// @dev futureATime is a unix timestamp and will only overflow in the year 2554
    uint64 futureATime;
}

/// @notice Trident exchange pool template with hybrid like-kind formula for swapping between an ERC-20 token pair.
contract StablePair is ReservoirPair {
    using FactoryStoreLib for GenericFactory;
    using Bytes32Lib for bytes32;

    event RampA(uint64 initialAPrecise, uint64 futureAPrecise, uint64 initialTime, uint64 futureTme);
    event StopRampA(uint64 currentAPrecise, uint64 time);

    AmplificationData public ampData;

    // We need the 2 variables below to calculate the growth in liquidity between
    // minting and burning, for the purpose of calculating platformFee.
    uint192 private lastInvariant;
    uint64 private lastInvariantAmp;

    constructor(address aToken0, address aToken1) Pair(aToken0, aToken1)
    {
        ampData.initialA        = factory.read("SP::amplificationCoefficient").toUint64() * uint64(StableMath.A_PRECISION);
        ampData.futureA         = ampData.initialA;
        // perf: check if intermediate variable is cheaper than two casts (optimizer might already catch it)
        ampData.initialATime    = uint64(block.timestamp);
        ampData.futureATime     = uint64(block.timestamp);

        swapFee = uint256(factory.get(keccak256("SP::swapFee")));

        // @dev Factory ensures that the tokens are sorted.
        require(token0 != address(0), "SP: ZERO_ADDRESS");
        require(token0 != token1, "SP: IDENTICAL_ADDRESSES");
        require(
            // perf: check if an immutable/constant var is cheaper than always casting
            ampData.initialA >= StableMath.MIN_A * uint64(StableMath.A_PRECISION)
            && ampData.initialA <= StableMath.MAX_A * uint64(StableMath.A_PRECISION),
            "INVALID_A"
        );
        require(swapFee <= MAX_SWAP_FEE, "SP: INVALID_SWAP_FEE");
    }

    function updateSwapFee() public {
        uint256 _swapFee = customSwapFee != type(uint).max
            ? customSwapFee
            : uint256(factory.get(keccak256("SP::swapFee")));
        if (_swapFee == swapFee) { return; }

        require(_swapFee <= MAX_SWAP_FEE, "SP: INVALID_SWAP_FEE");

        emit SwapFeeChanged(swapFee, _swapFee);
        swapFee = _swapFee;
    }

    function rampA(uint64 futureARaw, uint64 futureATime) external onlyFactory {
        require(
            futureARaw >= StableMath.MIN_A
            && futureARaw <= StableMath.MAX_A,
            "SP: INVALID_A"
        );

        uint64 futureAPrecise = futureARaw * uint64(StableMath.A_PRECISION);

        uint256 duration = futureATime - block.timestamp;
        require(duration >= StableMath.MIN_RAMP_TIME, "SP: INVALID_DURATION");

        uint64 currentAPrecise = _getCurrentAPrecise();

        // daily rate = (futureA / currentA) / duration * 1 day
        // we do multiplication first before division to avoid
        // losing precision
        uint256 dailyRate = futureAPrecise > currentAPrecise
            ? Math.ceilDiv(futureAPrecise * 1 days, currentAPrecise * duration)
            : Math.ceilDiv(currentAPrecise * 1 days, futureAPrecise * duration);
        require(dailyRate <= StableMath.MAX_AMP_UPDATE_DAILY_RATE, "SP: AMP_RATE_TOO_HIGH");

        ampData.initialA = currentAPrecise;
        ampData.futureA = futureAPrecise;
        ampData.initialATime = uint64(block.timestamp);
        ampData.futureATime = futureATime;

        emit RampA(currentAPrecise, futureAPrecise, uint64(block.timestamp), futureATime);
    }

    function stopRampA() external onlyFactory {
        uint64 currentAPrecise = _getCurrentAPrecise();

        ampData.initialA = currentAPrecise;
        ampData.futureA = currentAPrecise;
        // perf: check performance of using intermediate variable instead of struct property
        ampData.initialATime =  uint64(block.timestamp);
        ampData.futureATime = ampData.initialATime;

        emit StopRampA(currentAPrecise, ampData.initialATime);
    }

    /// @dev This fee is charged to cover for `swapFee` when users add unbalanced liquidity.
    function _nonOptimalMintFee(
        uint256 _amount0,
        uint256 _amount1,
        uint256 _reserve0,
        uint256 _reserve1
    ) internal view returns (uint256 token0Fee, uint256 token1Fee) {
        if (_reserve0 == 0 || _reserve1 == 0) return (0, 0);
        uint256 amount1Optimal = (_amount0 * _reserve1) / _reserve0;

        if (amount1Optimal <= _amount1) {
            token1Fee = (swapFee * (_amount1 - amount1Optimal)) / (2 * FEE_ACCURACY);
        } else {
            uint256 amount0Optimal = (_amount1 * _reserve0) / _reserve1;
            token0Fee = (swapFee * (_amount0 - amount0Optimal)) / (2 * FEE_ACCURACY);
        }
        require(token0Fee <= type(uint112).max && token1Fee <= type(uint112).max, "SP: NON_OPTIMAL_FEE_TOO_LARGE");
    }

    /// @dev Mints LP tokens - should be called via the router after transferring tokens.
    /// The router must ensure that sufficient LP tokens are minted by using the return value.
    function mint(address to) public nonReentrant returns (uint256 liquidity) {
        _syncManaged();

        (uint112 _reserve0, uint112 _reserve1, ) = getReserves();
        (uint256 balance0, uint256 balance1) = _balance();

        uint256 newLiq = _computeLiquidity(balance0, balance1);
        uint256 amount0 = balance0 - _reserve0;
        uint256 amount1 = balance1 - _reserve1;

        (uint256 fee0, uint256 fee1) = _nonOptimalMintFee(amount0, amount1, _reserve0, _reserve1);
        _reserve0 += uint112(fee0);
        _reserve1 += uint112(fee1);

        (uint256 _totalSupply, uint256 oldLiq) = _mintFee(_reserve0, _reserve1);

        if (_totalSupply == 0) {
            require(amount0 > 0 && amount1 > 0, "SP: INVALID_AMOUNTS");
            liquidity = newLiq - MINIMUM_LIQUIDITY;
            _mint(address(0), MINIMUM_LIQUIDITY);
        } else {
            liquidity = ((newLiq - oldLiq) * _totalSupply) / oldLiq;
        }
        require(liquidity != 0, "SP: INSUFFICIENT_LIQ_MINTED");
        _mint(to, liquidity);
        _update(balance0, balance1, _reserve0, _reserve1);

        // casting is safe as the max invariant would be 2 * uint112 (* uint60 in the case of tokens with 0 decimal places)
        // which results in 112 + 60 + 1 = 173 bits
        // which fits into uint192
        lastInvariant = uint192(newLiq);
        lastInvariantAmp = _getCurrentAPrecise();

        emit Mint(msg.sender, amount0, amount1);

        _managerCallback();
    }

    /// @dev Burns LP tokens sent to this contract. The router must ensure that the user gets sufficient output tokens.
    function burn(address to) public nonReentrant returns (uint256 amount0, uint256 amount1) {
        _syncManaged();

        (uint256 _reserve0, uint256 _reserve1, ) = getReserves();
        uint256 liquidity = balanceOf[address(this)];

        // this is a safety feature that prevents revert when removing liquidity
        // i.e. removing liquidity should always succeed under all circumstances
        // so if the iterative functions revert, we just have to forgo the platformFee calculations
        // and use the current totalSupply of LP tokens for calculations since there is no new
        // LP tokens minted for platformFee
        uint256 _totalSupply;
        try StablePair(this).mintFee(_reserve0, _reserve1) returns (uint256 rTotalSupply, uint256) {
            _totalSupply = rTotalSupply;
        }
        catch {
            _totalSupply = totalSupply;
        }

        amount0 = (liquidity * _reserve0) / _totalSupply;
        amount1 = (liquidity * _reserve1) / _totalSupply;

        _burn(address(this), liquidity);
        _safeTransfer(token0, to, amount0);
        _safeTransfer(token1, to, amount1);

        _update(_totalToken0(), _totalToken1(), reserve0, reserve1);

        lastInvariant = uint192(_computeLiquidity(reserve0, reserve1));
        lastInvariantAmp = _getCurrentAPrecise();

        emit Burn(msg.sender, amount0, amount1);

        _managerCallback();
    }

    /// @inheritdoc IPair
    function swap(int256 amount, bool inOrOut, address to, bytes calldata data) external nonReentrant returns (uint256 amountOut) {
        require(amount != 0, "SP: AMOUNT_ZERO");
        (uint112 _reserve0, uint112 _reserve1, ) = getReserves();
        uint256 amountIn;
        address tokenOut;

        // exact in
        if (inOrOut) {
            // swap token0 exact in for token1 variable out
            if (amount > 0) {
                tokenOut = token1;
                amountIn = uint256(amount);
                amountOut = _getAmountOut(amountIn, _reserve0, _reserve1, true);
            }
            // swap token1 exact in for token0 variable out
            else {
                tokenOut = token0;
                amountIn = uint256(-amount);
                amountOut = _getAmountOut(amountIn, _reserve0, _reserve1, false);
            }
        }
        // exact out
        else {
            // swap token1 variable in for token0 exact out
            if (amount > 0) {
                amountOut = uint256(amount);
                require(amountOut < _reserve0, "SP: NOT_ENOUGH_LIQ");
                tokenOut = token0;
                amountIn = _getAmountIn(amountOut, _reserve0, _reserve1, true);
            }
            // swap token0 variable in for token1 exact out
            else {
                amountOut = uint256(-amount);
                require(amountOut < _reserve1, "SP: NOT_ENOUGH_LIQ");
                tokenOut = token1;
                amountIn = _getAmountIn(amountOut, _reserve0, _reserve1, false);
            }
        }

        // optimistically transfers tokens
        _safeTransfer(tokenOut, to, amountOut);

        if (data.length > 0) {
            IReservoirCallee(to).reservoirCall(
                msg.sender,
                tokenOut == token0 ? amountOut : 0,
                tokenOut == token1 ? amountOut : 0,
                data
            );
        }

        uint256 balance0 = _totalToken0();
        uint256 balance1 = _totalToken1();

        uint256 actualAmountIn =
            tokenOut == token0
            ? balance1 - _reserve1
            : balance0 - _reserve0;
        require(amountIn <= actualAmountIn, "SP: INSUFFICIENT_AMOUNT_IN");

        _update(balance0, balance1, _reserve0, _reserve1);
        emit Swap(msg.sender, tokenOut == token1, actualAmountIn, amountOut, to);
    }

    function mintFee(uint256 _reserve0, uint256 _reserve1) public returns (uint256 _totalSupply, uint256 d) {
        require(msg.sender == address(this), "SP: NOT_SELF");
        return _mintFee(_reserve0, _reserve1);
    }

    function _update(uint256 totalToken0, uint256 totalToken1, uint112 _reserve0, uint112 _reserve1) internal override {
        require(totalToken0 <= type(uint112).max && totalToken1 <= type(uint112).max, "SP: OVERFLOW");

        uint32 blockTimestamp = uint32(block.timestamp % 2**32);
        uint32 timeElapsed;
        unchecked {
            timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired
        }

        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            _updateOracle(
                uint256(_reserve0),
                uint256(_reserve1),
                timeElapsed,
                blockTimestampLast
            );
        }
        reserve0 = uint112(totalToken0);
        reserve1 = uint112(totalToken1);
        blockTimestampLast = blockTimestamp;
        emit Sync(reserve0, reserve1);
    }

    function _balance() internal view returns (uint256 balance0, uint256 balance1) {
        balance0 = _totalToken0();
        balance1 = _totalToken1();
    }

    function _getAmountOut(
        uint256 amountIn,
        uint256 _reserve0,
        uint256 _reserve1,
        bool token0In
    ) internal view returns (uint256) {
        return StableMath._getAmountOut(
            amountIn,
            _reserve0,
            _reserve1,
            token0PrecisionMultiplier,
            token1PrecisionMultiplier,
            token0In,
            swapFee,
            _getNA()
        );
    }

    function _getAmountIn(
        uint256 amountOut,
        uint256 _reserve0,
        uint256 _reserve1,
        bool token0Out
    ) internal view returns (uint256) {
        return StableMath._getAmountIn(
            amountOut,
            _reserve0,
            _reserve1,
            token0PrecisionMultiplier,
            token1PrecisionMultiplier,
            token0Out,
            swapFee,
            _getNA()
        );
    }

    /// @notice Get D, the StableSwap invariant, based on a set of balances and a particular A.
    /// See the StableSwap paper for details.
    /// @dev Originally https://github.com/saddle-finance/saddle-contract/blob/0b76f7fb519e34b878aa1d58cffc8d8dc0572c12/contracts/SwapUtils.sol#L319.
    /// @return liquidity The invariant, at the precision of the pool.
    function _computeLiquidity(uint256 _reserve0, uint256 _reserve1) internal view returns (uint256 liquidity) {
    unchecked {
        uint256 adjustedReserve0 = _reserve0 * token0PrecisionMultiplier;
        uint256 adjustedReserve1 = _reserve1 * token1PrecisionMultiplier;
        liquidity = StableMath._computeLiquidityFromAdjustedBalances(adjustedReserve0, adjustedReserve1, _getNA());
    }
    }

    function _mintFee(uint256 _reserve0, uint256 _reserve1) internal returns (uint256 _totalSupply, uint256 d) {
        _totalSupply = totalSupply;
        uint256 _dLast = lastInvariant;
        if (_dLast != 0) {
            d = StableMath._computeLiquidityFromAdjustedBalances(
                _reserve0 * token0PrecisionMultiplier,
                _reserve1 * token1PrecisionMultiplier,
                2 * lastInvariantAmp
            );
            if (d > _dLast) {
                // @dev `platformFee` % of increase in liquidity.
                uint256 _platformFee = platformFee;
                uint256 numerator = _totalSupply * (d - _dLast) * _platformFee;
                uint256 denominator = (FEE_ACCURACY - _platformFee) * d + _platformFee * _dLast;
                uint256 liquidity = numerator / denominator;

                if (liquidity != 0) {
                    address platformFeeTo = factory.read("Shared::platformFeeTo").toAddress();

                    _mint(platformFeeTo, liquidity);
                    _totalSupply += liquidity;
                }
            }
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
            }
            else {
                uint64 rampDelta = initialA - futureA;
                rCurrentA = initialA - rampElapsed * rampDelta / rampDuration;
            }
        }
        else {
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

    function getAmountOut(address tokenIn, uint256 amountIn) public view returns (uint256 finalAmountOut) {
        (uint256 _reserve0, uint256 _reserve1, ) = getReserves();

        if (tokenIn == token0) {
            finalAmountOut = _getAmountOut(amountIn, _reserve0, _reserve1, true);
        } else {
            require(tokenIn == token1, "SP: INVALID_INPUT_TOKEN");
            finalAmountOut = _getAmountOut(amountIn, _reserve0, _reserve1, false);
        }
    }

    function getVirtualPrice() public view returns (uint256 virtualPrice) {
        (uint256 _reserve0, uint256 _reserve1, ) = getReserves();
        uint256 d = _computeLiquidity(_reserve0, _reserve1);
        virtualPrice = (d * (uint256(10)**decimals)) / totalSupply;
    }

    function skim(address to) external nonReentrant {
        // todo: implement this
    }

    /*//////////////////////////////////////////////////////////////////////////
                                ORACLE METHODS
    //////////////////////////////////////////////////////////////////////////*/

    function _updateOracle(uint256 _reserve0, uint256 _reserve1, uint32 timeElapsed, uint32 timestampLast) internal override {
        Observation storage previous = observations[index];

        (int112 currLogPrice, int112 currLogLiq) = StableOracleMath.calcLogPriceAndLiq(
            _getCurrentAPrecise(),
            _reserve0 * token0PrecisionMultiplier,
            _reserve1 * token1PrecisionMultiplier
        );

        unchecked {
            int112 logAccPrice = previous.logAccPrice + currLogPrice * int112(int256(uint256(timeElapsed)));
            int112 logAccLiq = previous.logAccLiquidity + currLogLiq * int112(int256(uint256(timeElapsed)));
            index += 1;
            observations[index] = Observation(logAccPrice, logAccLiq, timestampLast);
        }
    }
}
