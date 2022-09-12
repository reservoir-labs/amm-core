// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import "@openzeppelin/token/ERC20/ERC20.sol";
import "@openzeppelin/utils/math/Math.sol";

import { Bytes32Lib } from "src/libraries/Bytes32.sol";
import { FactoryStoreLib } from "src/libraries/FactoryStore.sol";

import { GenericFactory } from "src/GenericFactory.sol";

import "src/interfaces/ITridentCallee.sol";
import "src/libraries/MathUtils.sol";
import "src/libraries/RebaseLibrary.sol";
import "src/libraries/StableMath.sol";
import "src/ReservoirPair.sol";
import "src/Pair.sol";

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
    using MathUtils for uint256;
    using RebaseLibrary for Rebase;
    using FactoryStoreLib for GenericFactory;
    using Bytes32Lib for bytes32;

    event RampA(uint64 initialAPrecise, uint64 futureAPrecise, uint64 initialTime, uint64 futureTme);
    event StopRampA(uint64 currentAPrecise, uint64 time);

    AmplificationData public ampData;

    /// @dev Multipliers for each pooled token's precision to get to POOL_PRECISION_DECIMALS.
    /// For example, TBTC has 18 decimals, so the multiplier should be 1. WBTC
    /// has 8, so the multiplier should be 10 ** 18 / 10 ** 8 => 10 ** 10.
    uint256 public immutable token0PrecisionMultiplier;
    uint256 public immutable token1PrecisionMultiplier;

    // We need the 2 variables below to calculate the growth in liquidity between
    // minting and burning, for the purpose of calculating platformFee.
    // We no longer store dLast as dLast is dependent on the amp coefficient, which is dynamic
    uint112 internal lastLiquidityEventReserve0;
    uint112 internal lastLiquidityEventReserve1;

    constructor(address aToken0, address aToken1) Pair(aToken0, aToken1)
    {
        ampData.initialA        = factory.read("ConstantProductPair::amplificationCoefficient").toUint64() * uint64(StableMath.A_PRECISION);
        ampData.futureA         = ampData.initialA;
        // perf: check if intermediate variable is cheaper than two casts (optimizer might already catch it)
        ampData.initialATime    = uint64(block.timestamp);
        ampData.futureATime     = uint64(block.timestamp);

        token0PrecisionMultiplier = uint256(10)**(18 - ERC20(token0).decimals());
        token1PrecisionMultiplier = uint256(10)**(18 - ERC20(token1).decimals());

        // @dev Factory ensures that the tokens are sorted.
        require(token0 != address(0), "SP: ZERO_ADDRESS");
        require(token0 != token1, "SP: IDENTICAL_ADDRESSES");
        require(swapFee >= MIN_SWAP_FEE && swapFee <= MAX_SWAP_FEE, "SP: INVALID_SWAP_FEE");
        require(
            // perf: check if an immutable/constant var is cheaper than always casting
            ampData.initialA >= StableMath.MIN_A * uint64(StableMath.A_PRECISION)
            && ampData.initialA <= StableMath.MAX_A * uint64(StableMath.A_PRECISION),
            "INVALID_A"
        );
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

    /// @dev Mints LP tokens - should be called via the router after transferring tokens.
    /// The router must ensure that sufficient LP tokens are minted by using the return value.
    function mint(address to) public nonReentrant returns (uint256 liquidity) {
        _syncManaged();

        (uint112 _reserve0, uint112 _reserve1, ) = _getReserves();
        (uint256 balance0, uint256 balance1) = _balance();

        uint256 newLiq = _computeLiquidity(balance0, balance1);
        uint256 amount0 = balance0 - _reserve0;
        uint256 amount1 = balance1 - _reserve1;

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

        lastLiquidityEventReserve0 = reserve0; // reserves are up to date
        lastLiquidityEventReserve1 = reserve1; // reserves are up to date

        emit Mint(msg.sender, amount0, amount1);

        _managerCallback();
    }

    /// @dev Burns LP tokens sent to this contract. The router must ensure that the user gets sufficient output tokens.
    function burn(address to) public nonReentrant returns (uint256 amount0, uint256 amount1) {
        _syncManaged();

        (uint256 balance0, uint256 balance1) = _balance();
        uint256 liquidity = balanceOf[address(this)];

        // this is a safety feature that prevents revert when removing liquidity
        // i.e. removing liquidity should always succeed under all circumstances
        // so if the iterative functions revert, we just have to forgo the platformFee calculations
        // and use the current totalSupply of LP tokens for calculations since there is no new
        // LP tokens minted for platformFee
        uint256 _totalSupply;
        try StablePair(this).mintFee(balance0, balance1) returns (uint256 rTotalSupply, uint256) {
            _totalSupply = rTotalSupply;
        }
        catch {
            _totalSupply = totalSupply;
        }

        amount0 = (liquidity * balance0) / _totalSupply;
        amount1 = (liquidity * balance1) / _totalSupply;

        _burn(address(this), liquidity);
        _safeTransfer(token0, to, amount0);
        _safeTransfer(token1, to, amount1);

        _update(_totalToken0(), _totalToken1(), reserve0, reserve1);

        lastLiquidityEventReserve0 = reserve0;
        lastLiquidityEventReserve1 = reserve1;

        emit Burn(msg.sender, amount0, amount1);

        _managerCallback();
    }

    /// @dev Swaps one token for another. The router must prefund this contract and ensure there isn't too much slippage.
    function swap(address tokenIn, address to) public nonReentrant returns (uint256 amountOut) {
        (uint112 _reserve0, uint112 _reserve1, uint256 balance0, uint256 balance1) = _getReservesAndBalances();
        uint256 amountIn;
        address tokenOut;

        if (tokenIn == token0) {
            tokenOut = token1;
        unchecked {
            amountIn = balance0 - _reserve0;
        }
            amountOut = _getAmountOut(amountIn, _reserve0, _reserve1, true);
        } else {
            require(tokenIn == token1, "SP: INVALID_INPUT_TOKEN");
            tokenOut = token0;
        unchecked {
            amountIn = balance1 - _reserve1;
        }
            amountOut = _getAmountOut(amountIn, _reserve0, _reserve1, false);
        }
        _safeTransfer(tokenOut, to, amountOut);
        _update(_totalToken0(), _totalToken1(), _reserve0, _reserve1);
        emit Swap(to, tokenIn, tokenOut, amountIn, amountOut);
    }

    /// @dev Swaps one token for another with payload. The router must support swap callbacks and ensure there isn't too much slippage.
    function flashSwap(address tokenIn, address to, uint256 amountIn, bytes memory context) public nonReentrant returns (uint256 amountOut) {
        (uint112 _reserve0, uint112 _reserve1, ) = _getReserves();
        address tokenOut;

        if (tokenIn == token0) {
            tokenOut = token1;
            amountOut = _getAmountOut(amountIn, _reserve0, _reserve1, true);
            _processSwap(token1, to, amountOut, context);
            uint256 balance0 = _totalToken0();
            require(balance0 - _reserve0 >= amountIn, "SP: INSUFFICIENT_AMOUNT_IN");
        } else {
            require(tokenIn == token1, "SP: INVALID_INPUT_TOKEN");
            tokenOut = token0;
            amountOut = _getAmountOut(amountIn, _reserve0, _reserve1, false);
            _processSwap(token0, to, amountOut, context);
            uint256 balance1 = _totalToken1();
            require(balance1 - _reserve1 >= amountIn, "SP: INSUFFICIENT_AMOUNT_IN");
        }
        _update(_totalToken0(), _totalToken1(), _reserve0, _reserve1);
        emit Swap(to, tokenIn, tokenOut, amountIn, amountOut);
    }

    function mintFee(uint256 _reserve0, uint256 _reserve1) public returns (uint256 _totalSupply, uint256 d) {
        require(msg.sender == address(this), "SP: NOT_SELF");
        return _mintFee(_reserve0, _reserve1);
    }

    function _processSwap(
        address tokenOut,
        address to,
        uint256 amountOut,
        bytes memory data
    ) internal {
        _safeTransfer(tokenOut, to, amountOut);
        if (data.length != 0) ITridentCallee(msg.sender).tridentSwapCallback(data);
    }

    function _getReserves() internal view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast) {
        (_reserve0, _reserve1, _blockTimestampLast) = (reserve0, reserve1, blockTimestampLast);
    }

    function _getReservesAndBalances()
    internal
    view
    returns (
        uint112 _reserve0,
        uint112 _reserve1,
        uint256 balance0,
        uint256 balance1
    )
    {
        (_reserve0, _reserve1) = (reserve0, reserve1);
        (balance0, balance1) = _balance();

        // TODO: take into account calculation of rebase tokens
        // Rebase memory total0 = bento.totals(token0);
        // Rebase memory total1 = bento.totals(token1);

        // _reserve0 = total0.toElastic(_reserve0);
        // _reserve1 = total1.toElastic(_reserve1);
        // balance0 = total0.toElastic(balance0);
        // balance1 = total1.toElastic(balance1);
    }

    // todo: currently the reserve arguments are not used but will be used once we implement the oracle
    function _update(uint256 totalToken0, uint256 totalToken1, uint112 _reserve0, uint112 _reserve1) internal override {
        require(totalToken0 <= type(uint112).max && totalToken1 <= type(uint112).max, "SP: OVERFLOW");
        reserve0 = uint112(totalToken0);
        reserve1 = uint112(totalToken1);
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
    ) internal view returns (uint256 dy) {
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
        uint256 _dLast = _computeLiquidity(lastLiquidityEventReserve0, lastLiquidityEventReserve1);
        if (_dLast != 0) {
            d = _computeLiquidity(_reserve0, _reserve1);
            if (d > _dLast) {
                // @dev `platformFee` % of increase in liquidity.
                uint256 _platformFee = platformFee;
                uint256 numerator = _totalSupply * (d - _dLast) * _platformFee;
                uint256 denominator = (FEE_ACCURACY - _platformFee) * d + _platformFee * _dLast;
                uint256 liquidity = numerator / denominator;

                if (liquidity != 0) {
                    address platformFeeTo = factory.read("ConstantProductPair::platformFeeTo").toAddress();

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
        (uint256 _reserve0, uint256 _reserve1, ) = _getReserves();

        if (tokenIn == token0) {
            finalAmountOut = _getAmountOut(amountIn, _reserve0, _reserve1, true);
        } else {
            require(tokenIn == token1, "SP: INVALID_INPUT_TOKEN");
            finalAmountOut = _getAmountOut(amountIn, _reserve0, _reserve1, false);
        }
    }

    function getVirtualPrice() public view returns (uint256 virtualPrice) {
        (uint256 _reserve0, uint256 _reserve1, ) = _getReserves();
        uint256 d = _computeLiquidity(_reserve0, _reserve1);
        virtualPrice = (d * (uint256(10)**decimals)) / totalSupply;
    }

    function skim(address to) external nonReentrant {
        // todo: implement this
    }

    /*//////////////////////////////////////////////////////////////////////////
                                ORACLE METHODS
    //////////////////////////////////////////////////////////////////////////*/

    function _updateOracle(uint112 _reserve0, uint112 _reserve1, uint32 timeElapsed, uint32 timestampLast) internal override {
        // todo: implement this
    }
}
