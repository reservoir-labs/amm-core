pragma solidity 0.8.13;

import "@openzeppelin/token/ERC20/IERC20.sol";
import "@openzeppelin/token/ERC20/ERC20.sol";

import "@balancer-labs/v2-solidity-utils/contracts/helpers/WordCodec.sol";

import "../../UniswapV2Pair.sol";
import "./StableMath.sol";

contract UniswapV2StablePair is UniswapV2Pair {
    using WordCodec for bytes32;

    uint256 private constant _MIN_UPDATE_TIME = 1 days;
    uint256 private constant _MAX_AMP_UPDATE_DAILY_RATE = 2;

    uint256 internal _scalingFactor0;
    uint256 internal _scalingFactor1;

    bytes32 private _packedAmplificationData;

    // To track how many tokens are owed to the Vault as protocol fees, we measure and store the value of the invariant
    // after every join and exit. All invariant growth that happens between join and exit events is due to swap fees.
    uint256 internal _lastInvariant;

    // Because the invariant depends on the amplification parameter, and this value may change over time, we should only
    // compare invariants that were computed using the same value. We therefore store it whenever we store
    // _lastInvariant.
    uint256 internal _lastInvariantAmp;

    event AmpUpdateStarted(uint256 startValue, uint256 endValue, uint256 startTime, uint256 endTime);
    event AmpUpdateStopped(uint256 currentValue);

    // called once by the factory at time of deployment
    function initialize(
        address _token0,
        address _token1,
        uint _swapFee,
        uint _platformFee,
        uint _amplificationParameter
    ) external onlyFactory {
        _require(_amplificationParameter >= StableMath._MIN_AMP, Errors.MIN_AMP);
        _require(_amplificationParameter <= StableMath._MAX_AMP, Errors.MAX_AMP);

        token0 = _token0;
        token1 = _token1;
        swapFee = _swapFee;
        platformFee = _platformFee;

        _scalingFactor0 = _computeScalingFactor(IERC20(token0));
        _scalingFactor1 = _computeScalingFactor(IERC20(token1));

        uint256 initialAmp = BalancerMath.mul(_amplificationParameter, StableMath._AMP_PRECISION);
        _setAmplificationData(initialAmp);
    }

    function mint() external lock returns (uint liquidity) {
        // TODO: Code below is from StablePool::_onInitializePool
        // which is called when there is no liquidity in the pool
        // to review and cut as necessary
//        StablePoolUserData.JoinKind kind = userData.joinKind();
//        _require(kind == StablePoolUserData.JoinKind.INIT, Errors.UNINITIALIZED);
//
//        uint256[] memory amountsIn = userData.initialAmountsIn();
//        InputHelpers.ensureInputLengthMatch(amountsIn.length, _getTotalTokens());
//        _upscaleArray(amountsIn, scalingFactors);
//
//        (uint256 currentAmp, ) = _getAmplificationParameter();
//        uint256 invariantAfterJoin = StableMath._calculateInvariant(currentAmp, amountsIn, true);
//
//        // Set the initial BPT to the value of the invariant.
//        uint256 bptAmountOut = invariantAfterJoin;
//
//        _updateLastInvariant(invariantAfterJoin, currentAmp);
    }

    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external override lock {
        require(amount0Out > 0 || amount1Out > 0, "UniswapV2: INSUFFICIENT_OUTPUT_AMOUNT");
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        require(amount0Out < _reserve0 && amount1Out < _reserve1, "UniswapV2: INSUFFICIENT_LIQUIDITY");
    }

    /**
     * @dev Returns a scaling factor that, when multiplied to a token amount for `token`, normalizes its balance as if
     * it had 18 decimals.
     */
    function _computeScalingFactor(IERC20 token) internal view returns (uint256) {
        if (address(token) == address(this)) {
            return FixedPoint.ONE;
        }

        // Tokens that don't implement the `decimals` method are not supported.
        uint256 tokenDecimals = ERC20(address(token)).decimals();

        // Tokens with more than 18 decimals are not supported.
        uint256 decimalsDifference = BalancerMath.sub(18, tokenDecimals);
        return FixedPoint.ONE * 10**decimalsDifference;
    }

    function _setAmplificationData(uint256 value) private {
        _storeAmplificationData(value, value, block.timestamp, block.timestamp);
        emit AmpUpdateStopped(value);
    }

    function _setAmplificationData(
        uint256 startValue,
        uint256 endValue,
        uint256 startTime,
        uint256 endTime
    ) private {
        _storeAmplificationData(startValue, endValue, startTime, endTime);
        emit AmpUpdateStarted(startValue, endValue, startTime, endTime);
    }

    function _storeAmplificationData(
        uint256 startValue,
        uint256 endValue,
        uint256 startTime,
        uint256 endTime
    ) private {
        _packedAmplificationData =
        WordCodec.encodeUint(uint64(startValue), 0) |
        WordCodec.encodeUint(uint64(endValue), 64) |
        WordCodec.encodeUint(uint64(startTime), 64 * 2) |
        WordCodec.encodeUint(uint64(endTime), 64 * 3);
    }

    function _getAmplificationData()
    private
    view
    returns (
        uint256 startValue,
        uint256 endValue,
        uint256 startTime,
        uint256 endTime
    )
    {
        startValue = _packedAmplificationData.decodeUint64(0);
        endValue = _packedAmplificationData.decodeUint64(64);
        startTime = _packedAmplificationData.decodeUint64(64 * 2);
        endTime = _packedAmplificationData.decodeUint64(64 * 3);
    }

    /**
     * @dev Computes and stores the value of the invariant after a join, which is required to compute due protocol fees
     * in the future.
     */
    function _updateInvariantAfterJoin(uint256[] memory balances, uint256[] memory amountsIn) private {
        _mutateAmounts(balances, amountsIn, FixedPoint.add);

        (uint256 currentAmp, ) = _getAmplificationParameter();
        // This invariant is used only to compute the final balance when calculating the protocol fees. These are
        // rounded down, so we round the invariant up.
        _updateLastInvariant(StableMath._calculateInvariant(currentAmp, balances, true), currentAmp);
    }

    /**
     * @dev Computes and stores the value of the invariant after an exit, which is required to compute due protocol fees
     * in the future.
     */
    function _updateInvariantAfterExit(uint256[] memory balances, uint256[] memory amountsOut) private {
        _mutateAmounts(balances, amountsOut, FixedPoint.sub);

        (uint256 currentAmp, ) = _getAmplificationParameter();
        // This invariant is used only to compute the final balance when calculating the protocol fees. These are
        // rounded down, so we round the invariant up.
        _updateLastInvariant(StableMath._calculateInvariant(currentAmp, balances, true), currentAmp);
    }

    /**
     * @dev Stores the last measured invariant, and the amplification parameter used to compute it.
     */
    function _updateLastInvariant(uint256 invariant, uint256 amplificationParameter) internal {
        _lastInvariant = invariant;
        _lastInvariantAmp = amplificationParameter;
    }

    /**
     * @dev Mutates `amounts` by applying `mutation` with each entry in `arguments`.
     *
     * Equivalent to `amounts = amounts.map(mutation)`.
     */
    function _mutateAmounts(
        uint256[] memory toMutate,
        uint256[] memory arguments,
        function(uint256, uint256) pure returns (uint256) mutation
    ) private pure {
        for (uint256 i = 0; i < _getTotalTokens(); ++i) {
            toMutate[i] = mutation(toMutate[i], arguments[i]);
        }
    }

    function getAmplificationParameter()
        external
        view
        returns (
            uint256 value,
            bool isUpdating,
            uint256 precision
        )
    {
        (value, isUpdating) = _getAmplificationParameter();
        precision = StableMath._AMP_PRECISION;
    }

    function _getAmplificationParameter() internal view returns (uint256 value, bool isUpdating) {
        (uint256 startValue, uint256 endValue, uint256 startTime, uint256 endTime) = _getAmplificationData();

        // Note that block.timestamp >= startTime, since startTime is set to the current time when an update starts

        if (block.timestamp < endTime) {
            isUpdating = true;

            // We can skip checked arithmetic as:
            //  - block.timestamp is always larger or equal to startTime
            //  - endTime is always larger than startTime
            //  - the value delta is bounded by the largest amplification parameter, which never causes the
            //    multiplication to overflow.
            // This also means that the following computation will never revert nor yield invalid results.
            if (endValue > startValue) {
                value = startValue + ((endValue - startValue) * (block.timestamp - startTime)) / (endTime - startTime);
            } else {
                value = startValue - ((startValue - endValue) * (block.timestamp - startTime)) / (endTime - startTime);
            }
        } else {
            isUpdating = false;
            value = endValue;
        }
    }

    /**
     * @dev Hardcoded to 2 as we only support two assets in the pool
     */
    function _getTotalTokens() internal pure returns (uint256) {
        return 2;
    }

    /// ************* ROUTING FUNCTIONS **************** ////////
    /// ************* TO BE MOVED TO ROUTER LATER **************** ////////
}
