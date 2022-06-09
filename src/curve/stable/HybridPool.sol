// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.13;

import "@openzeppelin/security/ReentrancyGuard.sol";
import "@openzeppelin/token/ERC20/ERC20.sol";

import "src/UniswapV2ERC20.sol";
import "src/interfaces/IPool.sol";
import "src/interfaces/ITridentCallee.sol";
import "src/interfaces/IUniswapV2Factory.sol";
import "src/libraries/MathUtils.sol";
import "src/libraries/RebaseLibrary.sol";
import "src/libraries/StableMath.sol";

/// @notice Trident exchange pool template with hybrid like-kind formula for swapping between an ERC-20 token pair.
contract HybridPool is IPool, UniswapV2ERC20, ReentrancyGuard {
    using MathUtils for uint256;
    using RebaseLibrary for Rebase;

    event Mint(address indexed sender, uint256 amount0, uint256 amount1, address indexed recipient, uint256 liquidity);
    event Burn(address indexed sender, uint256 amount0, uint256 amount1, address indexed recipient, uint256 liquidity);
    event Sync(uint256 reserve0, uint256 reserve1);

    uint256 internal constant MINIMUM_LIQUIDITY = 10**3;
    uint8 internal constant PRECISION = 112;
    bytes4 private constant SELECTOR = bytes4(keccak256(bytes("transfer(address,uint256)")));

    /// @dev Constant value used as max loop limit.
    uint256 private constant MAX_LOOP_LIMIT = 256;
    uint256 internal constant MAX_FEE = 10000; // @dev 100%.
    uint256 public swapFee;
    uint256 public platformFee;

    address public immutable factory;
    address public token0;
    address public token1;
    uint256 public A;
    uint256 internal N_A; // @dev 2 * A.
    uint256 internal constant A_PRECISION = 100;

    /// @dev Multipliers for each pooled token's precision to get to POOL_PRECISION_DECIMALS.
    /// For example, TBTC has 18 decimals, so the multiplier should be 1. WBTC
    /// has 8, so the multiplier should be 10 ** 18 / 10 ** 8 => 10 ** 10.
    uint256 public token0PrecisionMultiplier;
    uint256 public token1PrecisionMultiplier;


    uint128 internal reserve0;
    uint128 internal reserve1;
    uint256 internal dLast;

    modifier onlyFactory() {
        require(msg.sender == factory, "UniswapV2: FORBIDDEN");
        _;
    }

    constructor() {
        factory = msg.sender;
    }

    function initialize(address _token0, address _token1, uint _swapFee, uint _platformFee, uint _a) external onlyFactory {
        // @dev Factory ensures that the tokens are sorted.
        token0 = _token0;
        token1 = _token1;
        swapFee = _swapFee;
        platformFee = _platformFee;
        A = _a;
        N_A = 2 * _a;
        token0PrecisionMultiplier = uint256(10)**(18 - ERC20(_token0).decimals());
        token1PrecisionMultiplier = uint256(10)**(18 - ERC20(_token1).decimals());
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

        dLast = newLiq;
        uint256 liquidityForEvent = liquidity;
        emit Mint(msg.sender, amount0, amount1, to, liquidityForEvent);
    }

    /// @dev Burns LP tokens sent to this contract. The router must ensure that the user gets sufficient output tokens.
    function burn(address to) public nonReentrant returns (IPool.TokenAmount[] memory withdrawnAmounts) {
        (uint256 balance0, uint256 balance1) = _balance();
        uint256 liquidity = balanceOf[address(this)];

        (uint256 _totalSupply, ) = _mintFee(balance0, balance1);

        uint256 amount0 = (liquidity * balance0) / _totalSupply;
        uint256 amount1 = (liquidity * balance1) / _totalSupply;

        _burn(address(this), liquidity);
        _safeTransfer(token0, to, amount0);
        _safeTransfer(token1, to, amount1);

        _updateReserves();

        withdrawnAmounts = new TokenAmount[](2);
        withdrawnAmounts[0] = TokenAmount({token: token0, amount: amount0});
        withdrawnAmounts[1] = TokenAmount({token: token1, amount: amount1});

        dLast = _computeLiquidity(balance0 - amount0, balance1 - amount1);

        emit Burn(msg.sender, amount0, amount1, to, liquidity);
    }

    /// @dev Swaps one token for another. The router must prefund this contract and ensure there isn't too much slippage.
    function swap(bytes calldata data) public override nonReentrant returns (uint256 amountOut) {
        (address tokenIn, address recipient) = abi.decode(data, (address, address));
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
        _safeTransfer(tokenOut, recipient, amountOut);
        _updateReserves();
        emit Swap(recipient, tokenIn, tokenOut, amountIn, amountOut);
    }

    /// @dev Swaps one token for another with payload. The router must support swap callbacks and ensure there isn't too much slippage.
    function flashSwap(bytes calldata data) public override nonReentrant returns (uint256 amountOut) {
        (address tokenIn, address recipient, uint256 amountIn, bytes memory context) = abi.decode(
            data,
            (address, address, uint256, bytes)
        );
        (uint256 _reserve0, uint256 _reserve1) = _getReserves();
        address tokenOut;

        if (tokenIn == token0) {
            tokenOut = token1;
            amountOut = StableMath._getAmountOut(amountIn, _reserve0, _reserve1, token0PrecisionMultiplier, token1PrecisionMultiplier, true, swapFee, N_A, A_PRECISION);
            _processSwap(token1, recipient, amountOut, context);
            uint256 balance0 = ERC20(token0).balanceOf(address(this));
            require(balance0 - _reserve0 >= amountIn, "INSUFFICIENT_AMOUNT_IN");
        } else {
            require(tokenIn == token1, "INVALID_INPUT_TOKEN");
            tokenOut = token0;
            amountOut = StableMath._getAmountOut(amountIn, _reserve0, _reserve1, token0PrecisionMultiplier, token1PrecisionMultiplier, false, swapFee, N_A, A_PRECISION);
            _processSwap(token0, recipient, amountOut, context);
            uint256 balance1 = ERC20(token1).balanceOf(address(this));
            require(balance1 - _reserve1 >= amountIn, "INSUFFICIENT_AMOUNT_IN");
        }
        _updateReserves();
        emit Swap(recipient, tokenIn, tokenOut, amountIn, amountOut);
    }

    /// @dev Updates `platformFee` for Trident protocol.
    function updatePlatformFee() public {
        platformFee = IUniswapV2Factory(factory).defaultPlatformFee();
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
                                        token0In, swapFee, N_A, A_PRECISION);
    }

    function _safeTransfer(address token, address to, uint value) private {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(SELECTOR, to, value));
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
        liquidity = StableMath._computeLiquidityFromAdjustedBalances(adjustedReserve0, adjustedReserve1, N_A, A_PRECISION);
    }
    }

    function _mintFee(uint256 _reserve0, uint256 _reserve1) internal returns (uint256 _totalSupply, uint256 d) {
        _totalSupply = totalSupply;
        uint256 _dLast = dLast;
        if (_dLast != 0) {
            d = _computeLiquidity(_reserve0, _reserve1);
            if (d > _dLast) {
                // @dev `platformFee` % of increase in liquidity.
                uint256 _platformFee = platformFee;
                uint256 numerator = _totalSupply * (d - _dLast) * _platformFee;
                uint256 denominator = (MAX_FEE - _platformFee) * d + _platformFee * _dLast;
                uint256 liquidity = numerator / denominator;

                if (liquidity != 0) {
                    _mint(IUniswapV2Factory(factory).platformFeeTo(), liquidity);
                    _totalSupply += liquidity;
                }
            }
        }
    }

    function getAssets() public view override returns (address[] memory assets) {
        assets = new address[](2);
        assets[0] = token0;
        assets[1] = token1;
    }

    function getAmountOut(bytes calldata data) public view override returns (uint256 finalAmountOut) {
        (address tokenIn, uint256 amountIn) = abi.decode(data, (address, uint256));
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
}
