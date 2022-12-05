pragma solidity ^0.8.0;

import { Math } from "src/libraries/Math.sol";
import { Bytes32Lib } from "src/libraries/Bytes32.sol";
import { FactoryStoreLib } from "src/libraries/FactoryStore.sol";
import { ConstantProductOracleMath } from "src/libraries/ConstantProductOracleMath.sol";
import { IReservoirCallee } from "src/interfaces/IReservoirCallee.sol";

import { GenericFactory } from "src/GenericFactory.sol";
import { ReservoirPair, Observation } from "src/ReservoirPair.sol";
import { IPair, Pair } from "src/Pair.sol";

contract ConstantProductPair is ReservoirPair {
    using FactoryStoreLib for GenericFactory;
    using Bytes32Lib for bytes32;

    // Accuracy^2:
    // 10_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000
    uint256 public constant SQUARED_ACCURACY = 1e76;
    // Accuracy: 100_000_000_000_000_000_000_000_000_000_000_000_000
    uint256 public constant ACCURACY = 1e38;

    string private constant PAIR_SWAP_FEE_NAME = "CP::swapFee";

    uint224 public kLast; // reserve0 * reserve1, as of immediately after the most recent liquidity event

    // solhint-disable-next-line no-empty-blocks
    constructor(address aToken0, address aToken1) Pair(aToken0, aToken1, PAIR_SWAP_FEE_NAME) { }

    function _getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut, uint256 swapFee)
        internal
        pure
        returns (uint256 amountOut)
    {
        require(amountIn > 0, "CP: INSUFFICIENT_INPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0, "CP: INSUFFICIENT_LIQUIDITY");

        uint256 amountInWithFee = amountIn * (FEE_ACCURACY - swapFee);
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * FEE_ACCURACY + amountInWithFee;
        amountOut = numerator / denominator;
    }

    function _getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut, uint256 swapFee)
        internal
        pure
        returns (uint256 amountIn)
    {
        require(amountOut > 0, "CP: INSUFFICIENT_OUTPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0, "CP: INSUFFICIENT_LIQUIDITY");

        uint256 numerator = reserveIn * amountOut * FEE_ACCURACY;
        uint256 denominator = (reserveOut - amountOut) * (FEE_ACCURACY - swapFee);
        amountIn = numerator / denominator + 1;
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
     * which remains a variable with range 0-50% here, but is fixed at (1/6)% in Uniswap V2.
     *
     * The mathematical equation:
     * If 'Fee' is the platform fee, and the previous and new values of the square-root of the invariant k, are
     * K1 and K2 respectively; this equation, in the form coded here can be expressed as:
     *
     *   _sharesToIssue = totalSupply * Fee * (1 - K1/K2) / ( 1 - Fee * (1 - K1/K2) )
     *
     * A reader of the whitepaper will note that this equation is not a literally the same as equation (6), however
     * with some straight-forward algebraic manipulation they can be shown to be mathematically equivalent.
     */
    function _calcFee(uint256 _sqrtNewK, uint256 _sqrtOldK, uint256 _platformFee, uint256 _circulatingShares)
        internal
        pure
        returns (uint256 _sharesToIssue)
    {
        // Assert newK & oldK        < uint112
        // Assert _platformFee       < FEE_ACCURACY
        // Assert _circulatingShares < uint112

        // perf: can be unchecked
        uint256 _scaledGrowth = _sqrtNewK * ACCURACY / _sqrtOldK; // ASSERT: < UINT256
        uint256 _scaledMultiplier = ACCURACY - (SQUARED_ACCURACY / _scaledGrowth); // ASSERT: < UINT128
        uint256 _scaledTargetOwnership = _scaledMultiplier * _platformFee / FEE_ACCURACY; // ASSERT: < UINT144 during maths, ends < UINT128

        _sharesToIssue = _scaledTargetOwnership * _circulatingShares / (ACCURACY - _scaledTargetOwnership); // ASSERT: _scaledTargetOwnership < ACCURACY
    }

    function _mintFee(uint112 _reserve0, uint112 _reserve1) private returns (bool feeOn) {
        feeOn = platformFee > 0;

        if (feeOn) {
            uint256 _sqrtOldK = Math.sqrt(kLast); // gas savings

            if (_sqrtOldK != 0) {
                uint256 _sqrtNewK = Math.sqrt(uint256(_reserve0) * _reserve1);

                if (_sqrtNewK > _sqrtOldK) {
                    uint256 _sharesToIssue = _calcFee(_sqrtNewK, _sqrtOldK, platformFee, totalSupply);

                    address platformFeeTo = factory.read(PLATFORM_FEE_TO_NAME).toAddress();
                    if (_sharesToIssue > 0) _mint(platformFeeTo, _sharesToIssue);
                }
            }
        } else if (kLast != 0) {
            kLast = 0;
        }
    }

    // this low-level function should be called from a contract which performs important safety checks
    function mint(address to) external nonReentrant returns (uint256 liquidity) {
        _syncManaged(); // check asset-manager pnl

        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        uint256 balance0 = _totalToken0();
        uint256 balance1 = _totalToken1();
        uint256 amount0 = balance0 - _reserve0;
        uint256 amount1 = balance1 - _reserve1;

        bool feeOn = _mintFee(_reserve0, _reserve1);
        uint256 _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        if (_totalSupply == 0) {
            liquidity = Math.sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY;
            _mint(address(0), MINIMUM_LIQUIDITY); // permanently lock the first MINIMUM_LIQUIDITY tokens
        } else {
            liquidity = Math.min(amount0 * _totalSupply / _reserve0, amount1 * _totalSupply / _reserve1);
        }
        require(liquidity > 0, "CP: INSUFFICIENT_LIQ_MINTED");
        _mint(to, liquidity);

        _update(balance0, balance1, _reserve0, _reserve1);
        if (feeOn) kLast = uint224(reserve0) * reserve1; // reserve0 and reserve1 are up-to-date
        emit Mint(msg.sender, amount0, amount1);

        _managerCallback();
    }

    // this low-level function should be called from a contract which performs important safety checks
    function burn(address to) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        _syncManaged(); // check asset-manager pnl

        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        uint256 balance0 = _totalToken0();
        uint256 balance1 = _totalToken1();
        uint256 liquidity = balanceOf[address(this)];

        bool feeOn = _mintFee(_reserve0, _reserve1);
        uint256 _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        amount0 = liquidity * balance0 / _totalSupply; // using balances ensures pro-rata distribution
        amount1 = liquidity * balance1 / _totalSupply; // using balances ensures pro-rata distribution
        _burn(address(this), liquidity);

        _checkedTransfer(token0, to, amount0, _reserve0, _reserve1);
        _checkedTransfer(token1, to, amount1, _reserve0, _reserve1);

        balance0 = _totalToken0();
        balance1 = _totalToken1();

        _update(balance0, balance1, _reserve0, _reserve1);
        if (feeOn) kLast = uint224(reserve0) * reserve1; // reserve0 and reserve1 are up-to-date
        emit Burn(msg.sender, amount0, amount1);

        _managerCallback();
    }

    /// @inheritdoc IPair
    function swap(int256 amount, bool inOrOut, address to, bytes calldata data)
        external
        nonReentrant
        returns (uint256 amountOut)
    {
        require(amount != 0, "CP: AMOUNT_ZERO");
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        uint256 amountIn;
        address tokenOut;

        // exact in
        if (inOrOut) {
            // swap token0 exact in for token1 variable out
            if (amount > 0) {
                tokenOut = token1;
                amountIn = uint256(amount);
                amountOut = _getAmountOut(amountIn, _reserve0, _reserve1, swapFee);
            }
            // swap token1 exact in for token0 variable out
            else {
                tokenOut = token0;
                amountIn = uint256(-amount);
                amountOut = _getAmountOut(amountIn, _reserve1, _reserve0, swapFee);
            }
        }
        // exact out
        else {
            // swap token1 variable in for token0 exact out
            if (amount > 0) {
                amountOut = uint256(amount);
                require(amountOut < _reserve0, "CP: NOT_ENOUGH_LIQ");
                tokenOut = token0;
                amountIn = _getAmountIn(amountOut, _reserve1, _reserve0, swapFee);
            }
            // swap token0 variable in for token1 exact out
            else {
                amountOut = uint256(-amount);
                require(amountOut < _reserve1, "CP: NOT_ENOUGH_LIQ");
                tokenOut = token1;
                amountIn = _getAmountIn(amountOut, _reserve0, _reserve1, swapFee);
            }
        }

        // optimistically transfers tokens
        _checkedTransfer(tokenOut, to, amountOut, _reserve0, _reserve1);

        if (data.length > 0) {
            IReservoirCallee(to).reservoirCall(
                msg.sender, tokenOut == token0 ? amountOut : 0, tokenOut == token1 ? amountOut : 0, data
            );
        }

        // perf: investigate if it is possible/safe to only do one call instead of two
        uint256 balance0 = _totalToken0();
        uint256 balance1 = _totalToken1();

        uint256 actualAmountIn = tokenOut == token0 ? balance1 - _reserve1 : balance0 - _reserve0;
        require(amountIn <= actualAmountIn, "CP: INSUFFICIENT_AMOUNT_IN");

        _update(balance0, balance1, _reserve0, _reserve1);
        emit Swap(msg.sender, tokenOut == token1, actualAmountIn, amountOut, to);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                ORACLE METHODS
    //////////////////////////////////////////////////////////////////////////*/

    function _updateOracle(uint256 _reserve0, uint256 _reserve1, uint32 timeElapsed, uint32 timestampLast)
        internal
        override
    {
        Observation storage previous = _observations[index];

        (uint256 currRawPrice, int112 currLogRawPrice) = ConstantProductOracleMath.calcLogPrice(
            _reserve0 * token0PrecisionMultiplier, _reserve1 * token1PrecisionMultiplier
        );
        // perf: see if we can avoid using prevClampedPrice and read the two previous oracle observations
        // to figure out the previous clamped price
        (uint256 currClampedPrice, int112 currLogClampedPrice) =
            _calcClampedPrice(currRawPrice, prevClampedPrice, timeElapsed);
        int112 currLogLiq = ConstantProductOracleMath.calcLogLiq(_reserve0, _reserve1);
        prevClampedPrice = currClampedPrice;

        // overflow is okay
        unchecked {
            int112 logAccRawPrice = previous.logAccRawPrice + currLogRawPrice * int112(int256(uint256(timeElapsed)));
            int56 logAccClampedPrice =
                previous.logAccClampedPrice + int56(currLogClampedPrice) * int56(int256(uint256(timeElapsed)));
            int56 logAccLiq = previous.logAccLiquidity + int56(currLogLiq) * int56(int256(uint256(timeElapsed)));
            index += 1;
            _observations[index] = Observation(logAccRawPrice, logAccClampedPrice, logAccLiq, timestampLast);
        }
    }
}
