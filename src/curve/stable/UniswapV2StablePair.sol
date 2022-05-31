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

    function getLastInvariant() external view returns (uint256 lastInvariant, uint256 lastInvariantAmp) {
        lastInvariant = _lastInvariant;
        lastInvariantAmp = _lastInvariantAmp;
    }

    function mint(address to) external override lock returns (uint liquidity) {
        // to refer to LegacyBasePool::onJoinPool as well

        // both reserves and balances are not scaled
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        uint balance0 = IERC20(token0).balanceOf(address(this));
        uint balance1 = IERC20(token1).balanceOf(address(this));
        // thus amounts are also not scaled
        uint amount0 = balance0 - _reserve0;
        uint amount1 = balance1 - _reserve1;

        uint scaledAmount0;
        uint scaledAmount1;

        uint _totalSupply = totalSupply;
        if (_totalSupply == 0) {
            (liquidity, scaledAmount0, scaledAmount1) = _onFirstMint(amount0, amount1);

            // note: Uniswap's MINIMUM_LIQUIDITY is 1e3, balancer's is 1e6
            // might need to reconcile this difference
            // also, balancer subtracts MINIMUM_LIQUIDITY from liquidity while uniswap doesn't
            // we are going to go with uniswap's approach since it is a really small number and would not
            // affect the users' shares and balances in any meaningful way
            _mint(address(0), MINIMUM_LIQUIDITY); // permanently lock the first MINIMUM_LIQUIDITY tokens

            // platformFee not applicable for first joining
        }
        else {
            // get scaled amounts and reserves
            scaledAmount0 = _upscale(amount0, _scalingFactor0);
            scaledAmount1 = _upscale(amount1, _scalingFactor1);
            uint scaledReserve0 = _upscale(_reserve0, _scalingFactor0);
            uint scaledReserve1 = _upscale(_reserve1, _scalingFactor1);

            (platformFeeToken, platformFeeAmount) = _onJoinPool(scaledAmount0, scaledAmount1, scaledReserve0, scaledReserve1);

            // pay platformFee if any
            if (platformFeeAmount > 0) {
                // platformFeeAmount is not scaled
                _safeTransfer(platformFeeToken, IUniswapV2Factory(factory).platformFeeTo(), platformFeeAmount);
            }
        }

        require(liquidity > 0, "UniswapV2: INSUFFICIENT_LIQUIDITY_MINTED");
//        if (platformFeeLiquidity > 0) { _mint(IUniswapV2Factory(factory).platformFeeTo(), platformFeeLiquidity); }
        _mint(to, liquidity);

        _update(balance0, balance1, _reserve0, _reserve1);
        // not using this kLast invariant anymore now are we?
        // if (feeOn) kLast = uint(reserve0) * reserve1; // reserve0 and reserve1 are up-to-date
        emit Mint(msg.sender, amount0, amount1);
    }

    function _onFirstMint(uint _amount0, uint _amount1) internal returns (uint liquidity, uint scaledAmount0, uint scaledAmount1) {
        // the code below is from StablePool::_onInitializePool
        // which is called when there is no liquidity in the pool
        scaledAmount0 = _upscale(_amount0, _scalingFactor0);
        scaledAmount1 = _upscale(_amount1, _scalingFactor1);

        (uint256 currentAmp, ) = _getAmplificationParameter();
        uint256[] memory balances = new uint256[](2);
        balances[0] = scaledAmount0;
        balances[1] = scaledAmount1;

        uint256 invariantAfterJoin = StableMath._calculateInvariant(currentAmp, balances, true);

        // Set the initial liquidity to the value of the invariant.
        liquidity = invariantAfterJoin;

        _updateLastInvariant(invariantAfterJoin, currentAmp);
    }

    function _onJoinPool(uint scaledAmount0, uint scaledAmount1, uint scaledReserve0, uint scaledReserve1) internal returns (address platformFeeToken, uint platformFeeAmount, uint liquidity) {

        // calculate how much platformFee to pay and in which token
        (platformFeeToken, platformFeeAmount) = _calculateDuePlatformFee(scaledReserve0, scaledReserve1);

        // subtract platformFee from the liquidity that the user should obtain
        if (platformFeeToken == token0) { scaledAmount0 = scaledAmount0 - platformFeeLiquidity; }
        else { scaledAmount1 = scaledAmount1 - platformFeeLiquidity; }

        uint256[] memory amountsIn = new uint256[](2);
        amountsIn[0] = scaledAmount0;
        amountsIn[1] = scaledAmount1;

        // calculate how much LP tokens to mint, after subtracting platformFees
        liquidity = _doJoin();

        // scale & round down the platformFees
        _downscaleDown(platformFeeAmount, platformFeeToken == token0 ? _scalingFactor0 : _scalingFactor1);
        _updateInvariantAfterJoin(balances, amountsIn);
    }

    function _calculateDuePlatformFee(uint scaledReserve0, uint scaledReserve1) internal returns (address platformFeeToken, uint amount) {
        platformFeeToken = address(0);
        amount = 0;
        if (platformFee == 0) { return (platformFeeToken, amount); }

        // we pay the platformFee in the more abundant token
        platformFeeToken = scaledReserve0 > scaledReserve1 ? token0 : token1;

        uint256[] memory balances = new uint256[](2);
        balances[0] = scaledReserve0;
        balances[1] = scaledReserve1;

        amount = StableMath._calcDueTokenProtocolSwapFeeAmount(
                    _lastInvariantAmp,
                    balances,
                    _lastInvariant,
                    platformFeeToken == token0 ? 0 : 1,
                    platformFee);
    }

    function _doJoin() internal returns (uint lpTokenAmount) {

    }

    function burn(address to) external override lock returns (uint amount0, uint amount1) {

        // Below is adapted from StablePool::_onExitPool
        // Exits are not completely disabled while the contract is paused: proportional exits (exact BPT in for tokens
        // out) remain functional.
//        if (_isNotPaused()) {
//            // Due protocol swap fee amounts are computed by measuring the growth of the invariant between the previous
//            // join or exit event and now - the invariant's growth is due exclusively to swap fees. This avoids
//            // spending gas calculating fee amounts during each individual swap
//            dueProtocolFeeAmounts = _getDueProtocolFeeAmounts(balances, protocolSwapFeePercentage);
//
//            // Update current balances by subtracting the protocol fee amounts
//            _mutateAmounts(balances, dueProtocolFeeAmounts, FixedPoint.sub);
//        } else {
//            // If the contract is paused, swap protocol fee amounts are not charged to avoid extra calculations and
//            // reduce the potential for errors.
//            dueProtocolFeeAmounts = new uint256[](_getTotalTokens());
//        }
//
//        (bptAmountIn, amountsOut) = _doExit(balances, scalingFactors, userData);
//
//        // Update the invariant with the balances the Pool will have after the exit, in order to compute the
//        // protocol swap fee amounts due in future joins and exits.
//        _updateInvariantAfterExit(balances, amountsOut);
//
//        return (bptAmountIn, amountsOut, dueProtocolFeeAmounts);
    }

    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external override lock {
        require(amount0Out > 0 || amount1Out > 0, "UniswapV2: INSUFFICIENT_OUTPUT_AMOUNT");
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        require(amount0Out < _reserve0 && amount1Out < _reserve1, "UniswapV2: INSUFFICIENT_LIQUIDITY");
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
     * @dev Returns the amount of protocol fees to pay, given the value of the last stored invariant and the current
     * balances.
     */
    function _getDueProtocolFeeAmounts(uint256[] memory balances, uint256 protocolSwapFeePercentage)
        private
        view
        returns (uint256[] memory)
    {
        // Initialize with zeros
        uint256[] memory dueProtocolFeeAmounts = new uint256[](_getTotalTokens());

        // Early return if the platform fee percentage is zero, saving gas.
        if (platformFee == 0) {
            return dueProtocolFeeAmounts;
        }

        // Instead of paying the protocol swap fee in all tokens proportionally, we will pay it in a single one. This
        // will reduce gas costs for single asset joins and exits, as at most only two Pool balances will change (the
        // token joined/exited, and the token in which fees will be paid).

        // The protocol fee is charged using the token with the highest balance in the pool.
        uint256 chosenTokenIndex = 0;
        uint256 maxBalance = balances[0];
        for (uint256 i = 1; i < _getTotalTokens(); ++i) {
            uint256 currentBalance = balances[i];
            if (currentBalance > maxBalance) {
                chosenTokenIndex = i;
                maxBalance = currentBalance;
            }
        }

        // Set the fee amount to pay in the selected token
        dueProtocolFeeAmounts[chosenTokenIndex] = StableMath._calcDueTokenProtocolSwapFeeAmount(
            _lastInvariantAmp,
            balances,
            _lastInvariant,
            chosenTokenIndex,
            protocolSwapFeePercentage
        );

        return dueProtocolFeeAmounts;
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
     * @dev Applies `scalingFactor` to `amount`, resulting in a larger or equal value depending on whether it needed
     * scaling or not.
     */
    function _upscale(uint256 amount, uint256 scalingFactor) internal pure returns (uint256) {
        // Upscale rounding wouldn't necessarily always go in the same direction: in a swap for example the balance of
        // token in should be rounded up, and that of token out rounded down. This is the only place where we round in
        // the same direction for all amounts, as the impact of this rounding is expected to be minimal (and there's no
        // rounding error unless `_scalingFactor()` is overriden).
        return FixedPoint.mulDown(amount, scalingFactor);
    }

    /**
     * @dev Reverses the `scalingFactor` applied to `amount`, resulting in a smaller or equal value depending on
     * whether it needed scaling or not. The result is rounded down.
     */
    function _downscaleDown(uint256 amount, uint256 scalingFactor) internal pure returns (uint256) {
        return FixedPoint.divDown(amount, scalingFactor);
    }

    /**
     * @dev Hardcoded to 2 as we only support two assets in the pool
     */
    function _getTotalTokens() internal pure returns (uint256) {
        return 2;
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

    function _getScalingFactor0() public view returns (uint256) {
        return _scalingFactor0;
    }

    function _getScalingFactor1() public view returns (uint256) {
        return _scalingFactor1;
    }

    /// ************* ROUTING FUNCTIONS **************** ////////
    /// ************* TO BE MOVED TO ROUTER LATER **************** ////////
}
