// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity =0.8.13;

import "@openzeppelin/security/ReentrancyGuard.sol";
import "@openzeppelin/token/ERC20/ERC20.sol";

import { Bytes32Lib } from "src/libraries/Bytes32.sol";
import { FactoryStoreLib } from "src/libraries/FactoryStore.sol";
import { GenericFactory } from "src/GenericFactory.sol";

import "src/UniswapV2ERC20.sol";
import "src/interfaces/ITridentCallee.sol";
import "src/libraries/MathUtils.sol";
import "src/libraries/RebaseLibrary.sol";
import "src/libraries/StableMath.sol";

struct AmplificationData {
    /// @dev both initialA and futureA are stored with A_PRECISION (i.e. multiplied by 100)
    uint64 initialA;
    uint64 futureA;
    uint64 initialATime;
    uint64 futureATime;
}

/// @notice Trident exchange pool template with hybrid like-kind formula for swapping between an ERC-20 token pair.
contract HybridPool is UniswapV2ERC20, ReentrancyGuard {
    using MathUtils for uint256;
    using RebaseLibrary for Rebase;
    using FactoryStoreLib for GenericFactory;
    using Bytes32Lib for bytes32;

    event Mint(address indexed sender, uint256 amount0, uint256 amount1, address indexed to, uint256 liquidity);
    event Burn(address indexed sender, uint256 amount0, uint256 amount1, address indexed to, uint256 liquidity);
    event Swap(address indexed to, address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);
    event Sync(uint256 reserve0, uint256 reserve1);
    event RampA(uint64 initialAPrecise, uint64 futureAPrecise, uint64 initialTime, uint64 futureTme);
    event StopRampA(uint64 currentAPrecise, uint64 time);
    event SwapFeeChanged(uint oldSwapFee, uint newSwapFee);
    event CustomSwapFeeChanged(uint oldCustomSwapFee, uint newCustomSwapFee);
    event PlatformFeeChanged(uint oldPlatformFee, uint newPlatformFee);
    event CustomPlatformFeeChanged(uint oldCustomPlatformFee, uint newCustomPlatformFee);

    uint256 internal constant MINIMUM_LIQUIDITY = 10**3;
    bytes4 private constant TRANSFER = bytes4(keccak256("transfer(address,uint256)"));

    uint8 internal constant PRECISION = 112;

    uint256 public constant FEE_ACCURACY     = 10_000;
    uint256 public constant MAX_PLATFORM_FEE = 5000;   // 50.00%
    uint256 public constant MIN_SWAP_FEE     = 1;      //  0.01%
    uint256 public constant MAX_SWAP_FEE     = 200;    //  2.00%

    AmplificationData public ampData;

    uint256 public swapFee;
    uint256 public customSwapFee = type(uint).max;

    uint256 public platformFee;
    uint256 public customPlatformFee = type(uint).max;

    GenericFactory public immutable factory;
    address public immutable token0;
    address public immutable token1;

    /// @dev Multipliers for each pooled token's precision to get to POOL_PRECISION_DECIMALS.
    /// For example, TBTC has 18 decimals, so the multiplier should be 1. WBTC
    /// has 8, so the multiplier should be 10 ** 18 / 10 ** 8 => 10 ** 10.
    uint256 public immutable token0PrecisionMultiplier;
    uint256 public immutable token1PrecisionMultiplier;

    uint128 internal reserve0;
    uint128 internal reserve1;
    /// @dev We need the 2 variables below to calculate the growth in liquidity between
    /// minting and burning, for the purpose of calculating platformFee.
    /// We no longer store dLast as dLast is dependent on the amp coefficient, which is dynamic
    uint128 internal lastLiquidityEventReserve0;
    uint128 internal lastLiquidityEventReserve1;

    modifier onlyFactory() {
        require(msg.sender == address(factory), "UniswapV2: FORBIDDEN");
        _;
    }

    constructor(address aToken0, address aToken1) {
        factory     = GenericFactory(msg.sender);
        token0      = aToken0;
        token1      = aToken1;
        swapFee     = factory.read("UniswapV2Pair::swapFee").toUint256();
        platformFee = factory.read("UniswapV2Pair::platformFee").toUint256();
        ampData.initialA = factory.read("UniswapV2Pair::amplificationCoefficient").toUint64() * uint64(StableMath.A_PRECISION);
        ampData.futureA = ampData.initialA;
        ampData.initialATime = uint64(block.timestamp);
        ampData.futureATime = uint64(block.timestamp);

        token0PrecisionMultiplier = uint256(10)**(18 - ERC20(token0).decimals());
        token1PrecisionMultiplier = uint256(10)**(18 - ERC20(token1).decimals());

        // @dev Factory ensures that the tokens are sorted.
        require(token0 != address(0), "ZERO_ADDRESS");
        require(token0 != token1, "IDENTICAL_ADDRESSES");
        require(swapFee >= MIN_SWAP_FEE && swapFee <= MAX_SWAP_FEE, "INVALID_SWAP_FEE");
        require(ampData.initialA >= StableMath.MIN_A * uint64(StableMath.A_PRECISION)
             && ampData.initialA <= StableMath.MAX_A * uint64(StableMath.A_PRECISION), "INVALID_A");
    }

    function setCustomSwapFee(uint _customSwapFee) external onlyFactory {
        // we assume the factory won't spam events, so no early check & return
        emit CustomSwapFeeChanged(customSwapFee, _customSwapFee);
        customSwapFee = _customSwapFee;

        updateSwapFee();
    }

    function setCustomPlatformFee(uint _customPlatformFee) external onlyFactory {
        emit CustomPlatformFeeChanged(customPlatformFee, _customPlatformFee);
        customPlatformFee = _customPlatformFee;

        updatePlatformFee();
    }

    function updateSwapFee() public {
        uint256 _swapFee = customSwapFee != type(uint).max
        ? customSwapFee
        : factory.read("UniswapV2Pair::swapFee").toUint256();
        if (_swapFee == swapFee) { return; }

        require(_swapFee >= MIN_SWAP_FEE && _swapFee <= MAX_SWAP_FEE, "UniswapV2: INVALID_SWAP_FEE");

        emit SwapFeeChanged(swapFee, _swapFee);
        swapFee = _swapFee;
    }

    function updatePlatformFee() public {
        uint256 _platformFee = customPlatformFee != type(uint).max
        ? customPlatformFee
        : factory.read("UniswapV2Pair::platformFee").toUint256();
        if (_platformFee == platformFee) { return; }

        require(_platformFee <= MAX_PLATFORM_FEE, "UniswapV2: INVALID_PLATFORM_FEE");

        emit PlatformFeeChanged(platformFee, _platformFee);
        platformFee = _platformFee;
    }

    function rampA(uint64 futureARaw, uint64 futureATime) external onlyFactory {
        require(
            futureARaw >= StableMath.MIN_A
         && futureARaw <= StableMath.MAX_A,
            "UniswapV2: INVALID A"
        );

        uint64 futureAPrecise = futureARaw * uint64(StableMath.A_PRECISION);

        uint256 duration = futureATime - block.timestamp;
        require(duration >= StableMath.MIN_RAMP_TIME, "UniswapV2: INVALID DURATION");

        uint64 currentAPrecise = _getCurrentAPrecise();

        // daily rate = (futureA / currentA) / duration * 1 day
        // we do multiplication first before division to avoid
        // losing precision
        uint256 dailyRate = futureAPrecise > currentAPrecise
            // balancer used divUp for this operation but I find no need for that
            ? (futureAPrecise * 1 days) / (currentAPrecise * duration)
            : (currentAPrecise * 1 days) / (futureAPrecise * duration);
        require(dailyRate <= StableMath.MAX_AMP_UPDATE_DAILY_RATE, "UniswapV2: AMP RATE TOO HIGH");

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
        ampData.initialATime =  uint64(block.timestamp);
        ampData.futureATime = ampData.initialATime;

        emit StopRampA(currentAPrecise, ampData.initialATime);
    }

    /// @dev Mints LP tokens - should be called via the router after transferring tokens.
    /// The router must ensure that sufficient LP tokens are minted by using the return value.
    function mint(address to) public nonReentrant returns (uint256 liquidity) {
        (uint256 _reserve0, uint256 _reserve1) = _getReserves();
        (uint256 balance0, uint256 balance1) = _balance();

        uint256 newLiq = _computeLiquidity(balance0, balance1);
        uint256 amount0 = balance0 - _reserve0;
        uint256 amount1 = balance1 - _reserve1;

        (uint256 _totalSupply, uint256 oldLiq) = _mintFee(_reserve0, _reserve1);

        if (_totalSupply == 0) {
            require(amount0 > 0 && amount1 > 0, "INVALID_AMOUNTS");
            liquidity = newLiq - MINIMUM_LIQUIDITY;
            _mint(address(0), MINIMUM_LIQUIDITY);
        } else {
            liquidity = ((newLiq - oldLiq) * _totalSupply) / oldLiq;
        }
        require(liquidity != 0, "INSUFFICIENT_LIQUIDITY_MINTED");
        _mint(to, liquidity);
        _updateReserves();

        lastLiquidityEventReserve0 = reserve0;
        lastLiquidityEventReserve1 = reserve1;

        uint256 liquidityForEvent = liquidity;
        emit Mint(msg.sender, amount0, amount1, to, liquidityForEvent);
    }

    /// @dev Burns LP tokens sent to this contract. The router must ensure that the user gets sufficient output tokens.
    function burn(address to) public nonReentrant returns (uint256[] memory withdrawnAmounts) {
        (uint256 balance0, uint256 balance1) = _balance();
        uint256 liquidity = balanceOf[address(this)];

        (uint256 _totalSupply, ) = _mintFee(balance0, balance1);

        uint256 amount0 = (liquidity * balance0) / _totalSupply;
        uint256 amount1 = (liquidity * balance1) / _totalSupply;

        _burn(address(this), liquidity);
        _safeTransfer(token0, to, amount0);
        _safeTransfer(token1, to, amount1);

        _updateReserves();

        withdrawnAmounts = new uint256[](2);
        withdrawnAmounts[0] = amount0;
        withdrawnAmounts[1] = amount1;

        lastLiquidityEventReserve0 = reserve0;
        lastLiquidityEventReserve1 = reserve1;
        emit Burn(msg.sender, amount0, amount1, to, liquidity);
    }

    /// @dev Swaps one token for another. The router must prefund this contract and ensure there isn't too much slippage.
    function swap(address tokenIn, address to) public nonReentrant returns (uint256 amountOut) {
        (uint256 _reserve0, uint256 _reserve1, uint256 balance0, uint256 balance1) = _getReservesAndBalances();
        uint256 amountIn;
        address tokenOut;

        if (tokenIn == token0) {
            tokenOut = token1;
        unchecked {
            amountIn = balance0 - _reserve0;
        }
            amountOut = _getAmountOut(amountIn, _reserve0, _reserve1, true);
        } else {
            require(tokenIn == token1, "INVALID_INPUT_TOKEN");
            tokenOut = token0;
        unchecked {
            amountIn = balance1 - _reserve1;
        }
            amountOut = _getAmountOut(amountIn, _reserve0, _reserve1, false);
        }
        _safeTransfer(tokenOut, to, amountOut);
        _updateReserves();
        emit Swap(to, tokenIn, tokenOut, amountIn, amountOut);
    }

    /// @dev Swaps one token for another with payload. The router must support swap callbacks and ensure there isn't too much slippage.
    function flashSwap(address tokenIn, address to, uint256 amountIn, bytes memory context) public nonReentrant returns (uint256 amountOut) {
        (uint256 _reserve0, uint256 _reserve1) = _getReserves();
        address tokenOut;

        if (tokenIn == token0) {
            tokenOut = token1;
            amountOut = _getAmountOut(amountIn, _reserve0, _reserve1, true);
            _processSwap(token1, to, amountOut, context);
            uint256 balance0 = ERC20(token0).balanceOf(address(this));
            require(balance0 - _reserve0 >= amountIn, "INSUFFICIENT_AMOUNT_IN");
        } else {
            require(tokenIn == token1, "INVALID_INPUT_TOKEN");
            tokenOut = token0;
            amountOut = _getAmountOut(amountIn, _reserve0, _reserve1, false);
            _processSwap(token0, to, amountOut, context);
            uint256 balance1 = ERC20(token1).balanceOf(address(this));
            require(balance1 - _reserve1 >= amountIn, "INSUFFICIENT_AMOUNT_IN");
        }
        _updateReserves();
        emit Swap(to, tokenIn, tokenOut, amountIn, amountOut);
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

    function _getReserves() internal view returns (uint256 _reserve0, uint256 _reserve1) {
        (_reserve0, _reserve1) = (reserve0, reserve1);
    }

    function _getReservesAndBalances()
    internal
    view
    returns (
        uint256 _reserve0,
        uint256 _reserve1,
        uint256 balance0,
        uint256 balance1
    )
    {
        (_reserve0, _reserve1) = (reserve0, reserve1);
        balance0 = ERC20(token0).balanceOf(address(this));
        balance1 = ERC20(token1).balanceOf(address(this));

        // TODO: take into account calculation of rebase tokens
        // Rebase memory total0 = bento.totals(token0);
        // Rebase memory total1 = bento.totals(token1);

        // _reserve0 = total0.toElastic(_reserve0);
        // _reserve1 = total1.toElastic(_reserve1);
        // balance0 = total0.toElastic(balance0);
        // balance1 = total1.toElastic(balance1);
    }

    function _updateReserves() internal {
        (uint256 _reserve0, uint256 _reserve1) = _balance();
        require(_reserve0 <= type(uint128).max && _reserve1 <= type(uint128).max, "OVERFLOW");
        reserve0 = uint128(_reserve0);
        reserve1 = uint128(_reserve1);
        emit Sync(_reserve0, _reserve1);
    }

    function _balance() internal view returns (uint256 balance0, uint256 balance1) {
        balance0 = ERC20(token0).balanceOf(address(this));
        balance1 = ERC20(token1).balanceOf(address(this));
    }

    function _getAmountOut(
        uint256 amountIn,
        uint256 _reserve0,
        uint256 _reserve1,
        bool token0In
    ) internal view returns (uint256 dy) {
        return StableMath._getAmountOut(amountIn, _reserve0, _reserve1,
                                        token0PrecisionMultiplier, token1PrecisionMultiplier,
                                        token0In, swapFee, _getNA());
    }

    function _safeTransfer(address token, address to, uint value) private {
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(TRANSFER, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "UniswapV2: TRANSFER_FAILED");
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
                    address platformFeeTo = factory.read("UniswapV2Pair::platformFeeTo").toAddress();

                    _mint(platformFeeTo, liquidity);
                    _totalSupply += liquidity;
                }
            }
        }
    }

    function _getCurrentAPrecise() internal view returns (uint64 currentA) {
        uint64 futureA = ampData.futureA;
        uint64 futureATime = ampData.futureATime;

        if (block.timestamp < futureATime) {
            uint64 initialA = ampData.initialA;
            uint64 initialATime = ampData.initialATime;
            uint64 rampTime = futureATime - initialATime;

            if (futureA > initialA) {
                currentA = initialA + (uint64(block.timestamp) - initialATime) * (futureA - initialA) / rampTime;
            }
            else {
                currentA = initialA - (uint64(block.timestamp) - initialATime) * (initialA - futureA) / rampTime;
            }
        }
        else {
            currentA = futureA;
        }
    }

    /// @dev number of coins in the pool multiplied by A precise
    function _getNA() internal view returns (uint256) {
        return 2 * _getCurrentAPrecise();
    }

    function getCurrentA() external view returns (uint64) {
        return _getCurrentAPrecise() / uint64(StableMath.A_PRECISION);
    }

    function getCurrentAPrecise() external view returns (uint64) {
        return _getCurrentAPrecise();
    }

    function getAssets() public view returns (address[] memory assets) {
        assets = new address[](2);
        assets[0] = token0;
        assets[1] = token1;
    }

    function getAmountOut(address tokenIn, uint256 amountIn) public view returns (uint256 finalAmountOut) {
        (uint256 _reserve0, uint256 _reserve1) = _getReserves();

        if (tokenIn == token0) {
            finalAmountOut = _getAmountOut(amountIn, _reserve0, _reserve1, true);
        } else {
            require(tokenIn == token1, "INVALID_INPUT_TOKEN");
            finalAmountOut = _getAmountOut(amountIn, _reserve0, _reserve1, false);
        }
    }

    function getReserves() public view returns (uint256 _reserve0, uint256 _reserve1) {
        (_reserve0, _reserve1) = _getReserves();
    }

    function getVirtualPrice() public view returns (uint256 virtualPrice) {
        (uint256 _reserve0, uint256 _reserve1) = _getReserves();
        uint256 d = _computeLiquidity(_reserve0, _reserve1);
        virtualPrice = (d * (uint256(10)**decimals)) / totalSupply;
    }

    function recoverToken(address token) external {
        address _recoverer = factory.read("UniswapV2Pair::defaultRecoverer").toAddress();
        require(token != token0, "UniswapV2: INVALID_TOKEN_TO_RECOVER");
        require(token != token1, "UniswapV2: INVALID_TOKEN_TO_RECOVER");
        require(_recoverer != address(0), "UniswapV2: RECOVERER_ZERO_ADDRESS");

        uint _amountToRecover = ERC20(token).balanceOf(address(this));

        _safeTransfer(token, _recoverer, _amountToRecover);
    }
}
