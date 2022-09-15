pragma solidity 0.8.13;

import "@openzeppelin/token/ERC20/IERC20.sol";
import "@openzeppelin/utils/math/SafeCast.sol";

import "src/libraries/Math.sol";
import "src/libraries/ConstantProductOracleMath.sol";
import "src/interfaces/IUniswapV2Callee.sol";

import { ReservoirPair } from "src/ReservoirPair.sol";
import { IPair, Pair } from "src/Pair.sol";

contract ConstantProductPair is ReservoirPair {
    using SafeCast for uint256;

    // Accuracy^2: 10_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000
    uint256 public constant SQUARED_ACCURACY = 1e76;
    // Accuracy: 100_000_000_000_000_000_000_000_000_000_000_000_000
    uint256 public constant ACCURACY         = 1e38;

    uint224 public kLast; // reserve0 * reserve1, as of immediately after the most recent liquidity event

    constructor(address aToken0, address aToken1) Pair(aToken0, aToken1)
    {} // solhint-disable-line no-empty-blocks

    // update reserves and, on the first call per block, price accumulators
    function _update(uint256 balance0, uint256 balance1, uint112 _reserve0, uint112 _reserve1) internal override {
        require(balance0 <= type(uint112).max && balance1 <= type(uint112).max, "CP: OVERFLOW");
        // solhint-disable-next-line not-rely-on-time
        uint32 blockTimestamp = uint32(block.timestamp % 2**32);
        uint32 timeElapsed;
        unchecked {
            timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired
        }

        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            _updateOracle(_reserve0, _reserve1, timeElapsed, blockTimestampLast);
        }
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        blockTimestampLast = blockTimestamp;
        emit Sync(reserve0, reserve1);
    }

    function _getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut, uint256 swapFee) internal pure returns (uint256 amountOut) {
        require(amountIn > 0, "CP: INSUFFICIENT_INPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0, "CP: INSUFFICIENT_LIQUIDITY");

        uint256 amountInWithFee = amountIn * (FEE_ACCURACY - swapFee);
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * FEE_ACCURACY + amountInWithFee;
        amountOut = numerator / denominator;
    }

    function _getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut, uint256 swapFee) internal pure returns (uint256 amountIn) {
        require(amountOut > 0, "CP: INSUFFICIENT_OUTPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0, "CP: INSUFFICIENT_LIQUIDITY");

        uint numerator = reserveIn * amountOut * FEE_ACCURACY;
        uint denominator = (reserveOut - amountOut) * (FEE_ACCURACY - swapFee);
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
    function _calcFee(uint _sqrtNewK, uint _sqrtOldK, uint _platformFee, uint _circulatingShares) internal pure returns (uint _sharesToIssue) {
        // Assert newK & oldK        < uint112
        // Assert _platformFee       < FEE_ACCURACY
        // Assert _circulatingShares < uint112

        // perf: can be unchecked
        uint256 _scaledGrowth = _sqrtNewK * ACCURACY / _sqrtOldK;                           // ASSERT: < UINT256
        uint256 _scaledMultiplier = ACCURACY - (SQUARED_ACCURACY / _scaledGrowth);          // ASSERT: < UINT128
        uint256 _scaledTargetOwnership = _scaledMultiplier * _platformFee / FEE_ACCURACY;   // ASSERT: < UINT144 during maths, ends < UINT128

        _sharesToIssue = _scaledTargetOwnership * _circulatingShares / (ACCURACY - _scaledTargetOwnership); // ASSERT: _scaledTargetOwnership < ACCURACY
    }

    function _mintFee(uint112 _reserve0, uint112 _reserve1) private returns (bool feeOn) {
        feeOn = platformFee > 0;

        if (feeOn) {
            uint _sqrtOldK = Math.sqrt(kLast); // gas savings

            if (_sqrtOldK != 0) {
                uint _sqrtNewK = Math.sqrt(uint(_reserve0) * _reserve1);

                if (_sqrtNewK > _sqrtOldK) {
                    uint _sharesToIssue = _calcFee(_sqrtNewK, _sqrtOldK, platformFee, totalSupply);

                    address platformFeeTo = address(uint160(uint256(factory.get(keccak256("ConstantProductPair::platformFeeTo")))));
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
        uint balance0 = _totalToken0();
        uint balance1 = _totalToken1();
        uint amount0 = balance0 - _reserve0;
        uint amount1 = balance1 - _reserve1;

        bool feeOn = _mintFee(_reserve0, _reserve1);
        uint _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
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
        address _token0 = token0;                                // gas savings
        address _token1 = token1;                                // gas savings
        uint balance0 = _totalToken0();
        uint balance1 = _totalToken1();
        uint liquidity = balanceOf[address(this)];

        bool feeOn = _mintFee(_reserve0, _reserve1);
        uint _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        amount0 = liquidity * balance0 / _totalSupply; // using balances ensures pro-rata distribution
        amount1 = liquidity * balance1 / _totalSupply; // using balances ensures pro-rata distribution
        require(amount0 > 0 && amount1 > 0, "CP: INSUFFICIENT_LIQ_BURNED");
        _burn(address(this), liquidity);
        _safeTransfer(_token0, to, amount0);
        _safeTransfer(_token1, to, amount1);
        balance0 = _totalToken0();
        balance1 = _totalToken1();

        _update(balance0, balance1, _reserve0, _reserve1);
        if (feeOn) kLast = uint224(reserve0) * reserve1; // reserve0 and reserve1 are up-to-date
        emit Burn(msg.sender, amount0, amount1);

        _managerCallback();
    }

    // this low-level function should be called from a contract which performs important safety checks
//    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external nonReentrant {
//        require(amount0Out > 0 || amount1Out > 0, "CP: INSUFFICIENT_OUTPUT_AMOUNT");
//        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
//        require(amount0Out < _reserve0 && amount1Out < _reserve1, "CP: INSUFFICIENT_LIQ_SWAP");
//
//        uint balance0;
//        uint balance1;
//        { // scope for _token{0,1}, avoids stack too deep errors
//            address _token0 = token0;
//            address _token1 = token1;
//            require(to != _token0 && to != _token1, "CP: INVALID_TO");
//            if (amount0Out > 0) _safeTransfer(_token0, to, amount0Out); // optimistically transfer tokens
//            if (amount1Out > 0) _safeTransfer(_token1, to, amount1Out); // optimistically transfer tokens
//            if (data.length > 0) IUniswapV2Callee(to).uniswapV2Call(msg.sender, amount0Out, amount1Out, data);
//            balance0 = _totalToken0();
//            balance1 = _totalToken1();
//        }
//        uint amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
//        uint amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;
//        require(amount0In > 0 || amount1In > 0, "CP: INSUFFICIENT_INPUT_AMOUNT");
//        { // scope for reserve{0,1}Adjusted, avoids stack too deep errors
//            uint balance0Adjusted = (balance0 * 10000) - (amount0In * swapFee);
//            uint balance1Adjusted = (balance1 * 10000) - (amount1In * swapFee);
//            require(balance0Adjusted * balance1Adjusted >= uint(_reserve0) * _reserve1 * (10000**2), "CP: K");
//        }
//
//        _update(balance0, balance1, _reserve0, _reserve1);
//        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
//    }

    /// @inheritdoc IPair
    function swap(int256 amount, bool inOrOut, address to, bytes calldata data) external nonReentrant returns (uint256 amountOut) {
        require(amount != 0, "CP: AMOUNT_ZERO");
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        uint256 amountIn;
        address tokenOut;

        // exact in
        if (inOrOut) {
            // swap token0 exact in for token1 variable out
            if (amount > 0) {
                tokenOut = token1;
                amountIn = _totalToken0() - _reserve0;
                require(amountIn == uint256(amount), "CP: AMOUNT_MISMATCH");
                amountOut = _getAmountOut(amountIn, _reserve0, _reserve1, swapFee);
            }
            // swap token1 exact in for token0 variable out
            else {
                tokenOut = token0;
                amountIn = _totalToken1() - _reserve1;
                require(amountIn == uint256(-amount), "CP: AMOUNT_MISMATCH");
                amountOut = _getAmountOut(amountIn, _reserve1, _reserve0, swapFee);
            }
        }
        // exact out
        else {
            uint256 actualAmountIn;
            // swap token1 variable in for token0 exact out
            if (amount > 0) {
                tokenOut = token1;
                amountOut = uint256(amount);
                amountIn = _getAmountIn(amountOut, _reserve1, _reserve0, swapFee);
                actualAmountIn = _totalToken1() - _reserve1;
            }
            // swap token0 variable in for token1 exact out
            else {
                tokenOut = token0;
                amountOut = uint256(-amount);
                amountIn = _getAmountIn(amountOut, _reserve0, _reserve1, swapFee);
                actualAmountIn = _totalToken0() - _reserve0;
            }
            require(amountIn <= actualAmountIn, "CP: INSUFFICIENT_AMOUNT_IN");
            if (amountIn < actualAmountIn) {
                // refund the user if the actualAmountIn is too much
                _safeTransfer(tokenOut == token0 ? token1 : token0, to, actualAmountIn - amountIn);
            }
            // do nothing if they are equal
        }

        require(_totalToken0() * _totalToken1() >= uint256(reserve0) * reserve1, "CP: K");
        _safeTransfer(tokenOut, to, amountOut);
        _update(_totalToken0(), _totalToken1(), _reserve0, _reserve1);
        emit Swap(msg.sender, tokenOut == token1, amountIn, amountOut, to);
    }

    // force balances to match reserves
    function skim(address to) external nonReentrant {
        address _token0 = token0; // gas savings
        address _token1 = token1; // gas savings
        _safeTransfer(_token0, to, _totalToken0() - reserve0);
        _safeTransfer(_token1, to, _totalToken1() - reserve1);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                ORACLE METHODS
    //////////////////////////////////////////////////////////////////////////*/

    function _updateOracle(uint112 _reserve0, uint112 _reserve1, uint32 timeElapsed, uint32 timestampLast) internal override {
        Observation storage previous = observations[index];

        int112 currLogPrice = ConstantProductOracleMath.calcLogPrice(_reserve0, _reserve1);
        int112 currLogLiq = ConstantProductOracleMath.calcLogLiq(_reserve0, _reserve1);

        // overflow is okay
        unchecked {
            int112 logAccPrice = previous.logAccPrice + currLogPrice * int112(int256(uint256(timeElapsed)));
            int112 logAccLiq = previous.logAccLiquidity + currLogLiq * int112(int256(uint256(timeElapsed)));
            index += 1;
            observations[index] = Observation(logAccPrice, logAccLiq, timestampLast);
        }
    }
}
