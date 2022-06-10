/* solhint-disable reason-string */
pragma solidity =0.8.13;

import "@openzeppelin/token/ERC20/IERC20.sol";
import "@openzeppelin/utils/math/SafeCast.sol";
import "src/UniswapV2ERC20.sol";
import "src/libraries/Math.sol";
import "src/libraries/UQ112x112.sol";
import "src/interfaces/IAssetManager.sol";
import "src/interfaces/IUniswapV2Pair.sol";
import "src/interfaces/IUniswapV2Factory.sol";
import "src/interfaces/IUniswapV2Callee.sol";

contract UniswapV2Pair is IUniswapV2Pair, UniswapV2ERC20 {
    using UQ112x112 for uint224;
    using SafeCast for uint256;

    uint public constant MINIMUM_LIQUIDITY = 10**3;
    bytes4 private constant SELECTOR = bytes4(keccak256(bytes("transfer(address,uint256)")));
    // Accuracy^2: 10_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000
    uint256 public constant SQUARED_ACCURACY = 1e76;
    // Accuracy: 100_000_000_000_000_000_000_000_000_000_000_000_000
    uint256 public constant ACCURACY         = 1e38;
    uint256 public constant FEE_ACCURACY     = 10_000;

    uint public swapFee;
    uint public customSwapFee;

    uint public platformFee;
    uint public customPlatformFee;

    address public factory;
    address public token0;
    address public token1;

    uint112 private reserve0;           // uses single storage slot, accessible via getReserves
    uint112 private reserve1;           // uses single storage slot, accessible via getReserves
    uint32  private blockTimestampLast; // uses single storage slot, accessible via getReserves

    uint public price0CumulativeLast;
    uint public price1CumulativeLast;
    uint public kLast; // reserve0 * reserve1, as of immediately after the most recent liquidity event

    uint private unlocked = 1;
    modifier lock() {
        require(unlocked == 1, "UniswapV2: LOCKED");
        unlocked = 0;
        _;
        unlocked = 1;
    }

    modifier onlyFactory() {
        require(msg.sender == factory, "UniswapV2: FORBIDDEN");
        _;
    }

    event SwapFeeChanged(uint oldSwapFee, uint newSwapFee);
    event CustomSwapFeeChanged(uint oldCustomSwapFee, uint newCustomSwapFee);
    event PlatformFeeChanged(uint oldPlatformFee, uint newPlatformFee);
    event CustomPlatformFeeChanged(uint oldCustomPlatformFee, uint newCustomPlatformFee);

    constructor() {
        factory = msg.sender;
    }

    function platformFeeOn() external view returns (bool _platformFeeOn) {
        _platformFeeOn = platformFee > 0;
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
        uint256 _swapFee = customSwapFee > 0
            ? customSwapFee
            : IUniswapV2Factory(factory).defaultSwapFee();

        if (_swapFee == swapFee) { return; }

        emit SwapFeeChanged(swapFee, _swapFee);
        swapFee = _swapFee;
    }

    function updatePlatformFee() public {
        uint256 _platformFee = customPlatformFee > 0
            ? customPlatformFee
            : IUniswapV2Factory(factory).defaultPlatformFee();

        if (_platformFee == platformFee) { return; }

        emit PlatformFeeChanged(platformFee, _platformFee);
        platformFee = _platformFee;
    }

    function getReserves() public view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast) {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }

    function _safeTransfer(address token, address to, uint value) private {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(SELECTOR, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "UniswapV2: TRANSFER_FAILED");
    }

    // called once by the factory at time of deployment
    function initialize(address _token0, address _token1, uint _swapFee, uint _platformFee) external onlyFactory {
        token0 = _token0;
        token1 = _token1;
        swapFee = _swapFee;
        platformFee = _platformFee;
    }

    // update reserves and, on the first call per block, price accumulators
    function _update(uint balance0, uint balance1, uint112 _reserve0, uint112 _reserve1) private {
        require(balance0 <= type(uint112).max && balance1 <= type(uint112).max, "UniswapV2: OVERFLOW");
        // solhint-disable-next-line not-rely-on-time
        uint32 blockTimestamp = uint32(block.timestamp % 2**32);
        uint32 timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired
        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            // * never overflows, and + overflow is desired
            price0CumulativeLast += uint(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) * timeElapsed;
            price1CumulativeLast += uint(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) * timeElapsed;
        }
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        blockTimestampLast = blockTimestamp;
        emit Sync(reserve0, reserve1);
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

                    address platformFeeTo = IUniswapV2Factory(factory).platformFeeTo();
                    if (_sharesToIssue > 0) _mint(platformFeeTo, _sharesToIssue);
                }
            }
        } else if (kLast != 0) {
            kLast = 0;
        }
    }

    // this low-level function should be called from a contract which performs important safety checks
    function mint(address to) external lock returns (uint liquidity) {
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        uint balance0 = _totalToken1();
        uint balance1 = _totalToken0();
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
        require(liquidity > 0, "UniswapV2: INSUFFICIENT_LIQUIDITY_MINTED");
        _mint(to, liquidity);

        _update(balance0, balance1, _reserve0, _reserve1);
        if (feeOn) kLast = uint(reserve0) * reserve1; // reserve0 and reserve1 are up-to-date
        emit Mint(msg.sender, amount0, amount1);
    }

    // this low-level function should be called from a contract which performs important safety checks
    function burn(address to) external lock returns (uint amount0, uint amount1) {
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        address _token0 = token0;                                // gas savings
        address _token1 = token1;                                // gas savings
        uint balance0 = _totalToken1();
        uint balance1 = _totalToken0();
        uint liquidity = balanceOf[address(this)];

        bool feeOn = _mintFee(_reserve0, _reserve1);
        uint _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        amount0 = liquidity * balance0 / _totalSupply; // using balances ensures pro-rata distribution
        amount1 = liquidity * balance1 / _totalSupply; // using balances ensures pro-rata distribution
        require(amount0 > 0 && amount1 > 0, "UniswapV2: INSUFFICIENT_LIQUIDITY_BURNED");
        _burn(address(this), liquidity);
        _safeTransfer(_token0, to, amount0);
        _safeTransfer(_token1, to, amount1);
        balance0 = _totalToken0();
        balance1 = _totalToken1();

        _update(balance0, balance1, _reserve0, _reserve1);
        if (feeOn) kLast = uint(reserve0) * reserve1; // reserve0 and reserve1 are up-to-date
        emit Burn(msg.sender, amount0, amount1, to);
    }

    // this low-level function should be called from a contract which performs important safety checks
    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external lock {
        require(amount0Out > 0 || amount1Out > 0, "UniswapV2: INSUFFICIENT_OUTPUT_AMOUNT");
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        require(amount0Out < _reserve0 && amount1Out < _reserve1, "UniswapV2: INSUFFICIENT_LIQUIDITY");

        uint balance0;
        uint balance1;
        { // scope for _token{0,1}, avoids stack too deep errors
            address _token0 = token0;
            address _token1 = token1;
            require(to != _token0 && to != _token1, "UniswapV2: INVALID_TO");
            if (amount0Out > 0) _safeTransfer(_token0, to, amount0Out); // optimistically transfer tokens
            if (amount1Out > 0) _safeTransfer(_token1, to, amount1Out); // optimistically transfer tokens
            if (data.length > 0) IUniswapV2Callee(to).uniswapV2Call(msg.sender, amount0Out, amount1Out, data);
            balance0 = _totalToken0();
            balance1 = _totalToken1();
        }
        uint amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
        uint amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;
        require(amount0In > 0 || amount1In > 0, "UniswapV2: INSUFFICIENT_INPUT_AMOUNT");
        { // scope for reserve{0,1}Adjusted, avoids stack too deep errors
            uint balance0Adjusted = (balance0 * 10000) - (amount0In * swapFee);
            uint balance1Adjusted = (balance1 * 10000) - (amount1In * swapFee);
            require(balance0Adjusted * balance1Adjusted >= uint(_reserve0) * _reserve1 * (10000**2), "UniswapV2: K");
        }

        _update(balance0, balance1, _reserve0, _reserve1);
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    // force balances to match reserves
    function skim(address to) external lock {
        address _token0 = token0; // gas savings
        address _token1 = token1; // gas savings
        _safeTransfer(_token0, to, _totalToken0() - reserve0);
        _safeTransfer(_token1, to, _totalToken1() - reserve1);
    }

    function recoverToken(address token) external {
        address _recoverer = IUniswapV2Factory(factory).defaultRecoverer();
        require(token != token0, "UniswapV2: INVALID_TOKEN_TO_RECOVER");
        require(token != token1, "UniswapV2: INVALID_TOKEN_TO_RECOVER");
        require(_recoverer != address(0), "UniswapV2: RECOVERER_ZERO_ADDRESS");

        uint _amountToRecover = IERC20(token).balanceOf(address(this));

        _safeTransfer(token, _recoverer, _amountToRecover);
    }

    // force reserves to match balances
    function sync() external lock {
        _update(_totalToken0(), _totalToken1(), reserve0, reserve1);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    ASSET MANAGER
    //////////////////////////////////////////////////////////////////////////*/

    IAssetManager public assetManager;

    function setManager(IAssetManager manager) external onlyFactory {
        assetManager = manager;
    }

    modifier onlyManager() {
        require(msg.sender == address(assetManager), "auth: not asset manager");
        _;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    ASSET MANAGEMENT

     Asset management is supported via a two-way interface. The pool is able to
     ask the current asset manager for the latest view of the balances. In turn
     the asset manager can move assets in/out of the pool. This section
     implements the pool-side of the equation. The manager's side is abstracted
     behind the IAssetManager interface.

    //////////////////////////////////////////////////////////////////////////*/

    uint256 public token0Invested;
    uint256 public token1Invested;

    function _token0Liquid() private returns (uint256) {
        return reserve0 - token0Invested;
    }

    function _token1Liquid() private returns (uint256) {
        return reserve1 - token1Invested;
    }

    function _totalToken0() private returns (uint256) {
        return IERC20(token0).balanceOf(address(this)) + token0Invested;
    }

    function _totalToken1() private returns (uint256) {
        return IERC20(token1).balanceOf(address(this)) + token1Invested;
    }

    event ProfitReported(address token, uint256 amount);
    event LossReported(address token, uint256 amount);

    function _handleReport(address token, uint256 prevBalance, uint256 currBalance) private {
        if (currBalance > prevBalance) {
            // report profit
            uint256 lProfit = currBalance - prevBalance;

            emit ProfitReported(token, lProfit);

            token == token0
                ? reserve0 += lProfit.toUint112()
                : reserve1 += lProfit.toUint112();
        }
        else if (currBalance < prevBalance) {
            // report loss
            uint256 lLoss = prevBalance - currBalance;

            emit LossReported(token, lLoss);

            // nb: loss cannot exceed sum of assets
            token == token0
                ? reserve0 -= uint112(lLoss)
                : reserve1 -= uint112(lLoss);
        }
        // else do nothing balance is equal
    }

    function syncBalances() external onlyManager {
        uint256 lToken0Invested = assetManager.getBalance(token0);
        uint256 lToken1Invested = assetManager.getBalance(token1);

        _handleReport(token0, token0Invested, lToken0Invested);
        _handleReport(token1, token1Invested, lToken1Invested);
    }

    function manageReserves(int256 token0Change, int256 token1Change) external onlyManager {
        if (token0Change > 0) {
            token0Invested -= uint256(token0Change);
        }
        else if (token0Change < 0) {
            // todo
            // push tokens to manager
            // update internal accounting
        }

        if (token1Change > 0) {
            // todo
            // pull tokens from manager
            // update internal accounting
        }
        else if (token1Change < 0) {
            // todo
            // push tokens to manager
            // update internal accounting
        }

        _update(
            _totalToken0(),
            _totalToken1(),
            reserve0,
            reserve1
        );
    }
}
