pragma solidity ^0.8.0;

import { ReservoirERC20, ERC20 } from "src/ReservoirERC20.sol";

import { FactoryStoreLib } from "src/libraries/FactoryStore.sol";
import { Bytes32Lib } from "src/libraries/Bytes32.sol";

struct Slot0 {
    uint104 reserve0;
    uint104 reserve1;
    uint32 packedTimestamp;
    uint16 index;
}

struct Observation {
    // natural log (ln) of the raw accumulated price (token1/token0)
    int112 logAccRawPrice;
    // natural log (ln) of the clamped accumulated price (token1/token0)
    // in the case of maximum price supported by the oracle (~2.87e56 == e ** 130.0000)
    // (1300000) 21 bits multiplied by 32 bits of the timestamp gives 53 bits
    // which fits into int56
    int56 logAccClampedPrice;
    // natural log (ln) of the accumulated liquidity (sqrt(x * y))
    // in the case of maximum liq (sqrt(uint104 * uint104) == 5.192e33 == e ** 77.5325)
    // (775325) 20 bits multiplied by 32 bits of the timestamp gives 52 bits
    // which fits into int56
    int56 logAccLiquidity;
    // overflows every 136 years, in the year 2106
    uint32 timestamp;
}

abstract contract ReservoirPair is ReservoirERC20 {
    using FactoryStoreLib for GenericFactory;
    using Bytes32Lib for bytes32;

    string internal constant PLATFORM_FEE_TO_NAME = "Shared::platformFeeTo";
    string private constant PLATFORM_FEE_NAME = "Shared::platformFee";
    string private constant RECOVERER_NAME = "Shared::defaultRecoverer";
    bytes4 private constant SELECTOR = bytes4(keccak256("transfer(address,uint256)"));

    uint256 public constant MINIMUM_LIQUIDITY = 10 ** 3;
    uint256 public constant FEE_ACCURACY = 1_000_000; // 100%
    uint256 public constant MAX_PLATFORM_FEE = 500_000; //  50%
    uint256 public constant MAX_SWAP_FEE = 20_000; //   2%

    GenericFactory public immutable factory;
    ERC20 public immutable token0;
    ERC20 public immutable token1;

    /// @dev Multipliers for each pooled token's precision to get to POOL_PRECISION_DECIMALS.
    /// For example, TBTC has 18 decimals, so the multiplier should be 1. WBTC
    /// has 8, so the multiplier should be 10 ** 18 / 10 ** 8 => 10 ** 10.
    uint128 internal immutable token0PrecisionMultiplier;
    uint128 internal immutable token1PrecisionMultiplier;

    Slot0 internal _slot0 = Slot0({reserve0: 0, reserve1: 0, packedTimestamp: 0, index: type(uint16).max});

    uint256 public swapFee;
    uint256 public customSwapFee = type(uint256).max;
    bytes32 internal immutable swapFeeName;

    uint256 public platformFee;
    uint256 public customPlatformFee = type(uint256).max;

    modifier onlyFactory() {
        require(msg.sender == address(factory), "P: FORBIDDEN");
        _;
    }

    constructor(address aToken0, address aToken1, string memory aSwapFeeName) {
        factory = GenericFactory(msg.sender);
        token0 = ERC20(aToken0);
        token1 = ERC20(aToken1);

        swapFeeName = keccak256(abi.encodePacked(aSwapFeeName));
        updateSwapFee();
        updatePlatformFee();

        token0PrecisionMultiplier = uint128(10) ** (18 - token0.decimals());
        token1PrecisionMultiplier = uint128(10) ** (18 - token1.decimals());

        updateOracleCaller();
        setAllowedChangePerSecond(factory.read(ALLOWED_CHANGE_NAME).toUint256());
    }

    function _currentTime() internal view returns (uint32) {
        return uint32(block.timestamp % 2 ** 31);
    }

    function _splitSlot0Timestamp(uint32 rRawTimestamp) internal pure returns (uint32 rTimestamp, bool rLocked) {
        rLocked = rRawTimestamp >> 31 == 1;
        rTimestamp = rRawTimestamp & 0x7FFFFFFF;
    }

    function _writeSlot0Timestamp(uint32 aTimestamp, bool aLocked) internal {
        uint32 lLocked = aLocked ? uint32(1 << 31) : uint32(0);
        _slot0.packedTimestamp = aTimestamp | lLocked;
    }

    function _lockAndLoad()
        internal
        returns (uint104 rReserve0, uint104 rReserve1, uint32 rBlockTimestampLast, uint16 rIndex)
    {
        Slot0 memory lSlot0 = _slot0;

        // Load slot0 values.
        bool lLock;
        rReserve0 = lSlot0.reserve0;
        rReserve1 = lSlot0.reserve1;
        (rBlockTimestampLast, lLock) = _splitSlot0Timestamp(lSlot0.packedTimestamp);
        rIndex = lSlot0.index;

        // Acquire reentrancy lock.
        require(!lLock, "REENTRANCY");
        _writeSlot0Timestamp(rBlockTimestampLast, true);
    }

    function _unlock(uint32 aBlockTimestampLast) internal {
        _writeSlot0Timestamp(aBlockTimestampLast, false);
    }

    function getReserves()
        public
        view
        returns (uint104 rReserve0, uint104 rReserve1, uint32 rBlockTimestampLast, uint16 rIndex)
    {
        Slot0 memory lSlot0 = _slot0;

        rReserve0 = lSlot0.reserve0;
        rReserve1 = lSlot0.reserve1;
        (rBlockTimestampLast,) = _splitSlot0Timestamp(lSlot0.packedTimestamp);
        rIndex = lSlot0.index;
    }

    /// @notice Force reserves to match balances.
    function sync() external {
        (uint104 lReserve0, uint104 lReserve1, uint32 lBlockTimestampLast,) = _lockAndLoad();
        (lReserve0, lReserve1) = _syncManaged(lReserve0, lReserve1);

        _updateAndUnlock(_totalToken0(), _totalToken1(), lReserve0, lReserve1, lBlockTimestampLast);
    }

    /// @notice Force balances to match reserves.
    function skim(address aTo) external {
        (uint104 lReserve0, uint104 lReserve1, uint32 lBlockTimestampLast,) = _lockAndLoad();

        _checkedTransfer(token0, aTo, _totalToken0() - lReserve0, lReserve0, lReserve1);
        _checkedTransfer(token1, aTo, _totalToken1() - lReserve1, lReserve0, lReserve1);
        _unlock(lBlockTimestampLast);
    }

    function setCustomSwapFee(uint256 _customSwapFee) external onlyFactory {
        // we assume the factory won't spam events, so no early check & return
        emit CustomSwapFeeChanged(customSwapFee, _customSwapFee);
        customSwapFee = _customSwapFee;

        updateSwapFee();
    }

    function setCustomPlatformFee(uint256 _customPlatformFee) external onlyFactory {
        emit CustomPlatformFeeChanged(customPlatformFee, _customPlatformFee);
        customPlatformFee = _customPlatformFee;

        updatePlatformFee();
    }

    function updateSwapFee() public {
        uint256 _swapFee = customSwapFee != type(uint256).max ? customSwapFee : factory.get(swapFeeName).toUint256();
        if (_swapFee == swapFee) return;

        require(_swapFee <= MAX_SWAP_FEE, "P: INVALID_SWAP_FEE");

        emit SwapFeeChanged(swapFee, _swapFee);
        swapFee = _swapFee;
    }

    function updatePlatformFee() public {
        uint256 _platformFee =
            customPlatformFee != type(uint256).max ? customPlatformFee : factory.read(PLATFORM_FEE_NAME).toUint256();
        if (_platformFee == platformFee) return;

        require(_platformFee <= MAX_PLATFORM_FEE, "P: INVALID_PLATFORM_FEE");

        emit PlatformFeeChanged(platformFee, _platformFee);
        platformFee = _platformFee;
    }

    function recoverToken(address token) external {
        address _recoverer = factory.read(RECOVERER_NAME).toAddress();
        require(token != address(token0), "P: INVALID_TOKEN_TO_RECOVER");
        require(token != address(token1), "P: INVALID_TOKEN_TO_RECOVER");
        require(_recoverer != address(0), "P: RECOVERER_ZERO_ADDRESS");

        uint256 _amountToRecover = ERC20(token).balanceOf(address(this));

        _safeTransfer(token, _recoverer, _amountToRecover);
    }

    function _safeTransfer(address token, address to, uint256 value) internal returns (bool) {
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(SELECTOR, to, value));
        return success && (data.length == 0 || abi.decode(data, (bool)));
    }

    /*//////////////////////////////////////////////////////////////////////////
                            ASSET MANAGEMENT

    Asset management is supported via a two-way interface. The pool is able to
    ask the current asset manager for the latest view of the balances. In turn
    the asset manager can move assets in/out of the pool. This section
    implements the pool side of the equation. The manager's side is abstracted
    behind the IAssetManager interface.

    //////////////////////////////////////////////////////////////////////////*/

    IAssetManager public assetManager;

    function setManager(IAssetManager manager) external onlyFactory {
        require(token0Managed == 0 && token1Managed == 0, "AMP: AM_STILL_ACTIVE");
        assetManager = manager;
    }

    uint104 public token0Managed;
    uint104 public token1Managed;

    function _totalToken0() internal view returns (uint256) {
        return token0.balanceOf(address(this)) + uint256(token0Managed);
    }

    function _totalToken1() internal view returns (uint256) {
        return token1.balanceOf(address(this)) + uint256(token1Managed);
    }

    function _handleReport(ERC20 aToken, uint104 aReserve, uint104 aPrevBalance, uint104 aNewBalance)
        private
        returns (uint104 rUpdatedReserve)
    {
        if (aNewBalance > aPrevBalance) {
            // report profit
            uint104 lProfit = aNewBalance - aPrevBalance;

            emit ProfitReported(aToken, lProfit);

            rUpdatedReserve = aReserve + lProfit;
        } else if (aNewBalance < aPrevBalance) {
            // report loss
            uint104 lLoss = aPrevBalance - aNewBalance;

            emit LossReported(aToken, lLoss);

            rUpdatedReserve = aReserve - lLoss;
        } else {
            // Balances are equal, return the original reserve.
            rUpdatedReserve = aReserve;
        }
    }

    function _syncManaged(uint104 aReserve0, uint104 aReserve1)
        internal
        returns (uint104 rReserve0, uint104 rReserve1)
    {
        if (address(assetManager) == address(0)) {
            // PERF: Is assigning to rReserve0 cheaper?
            return (aReserve0, aReserve1);
        }

        uint104 lToken0Managed = assetManager.getBalance(this, token0);
        uint104 lToken1Managed = assetManager.getBalance(this, token1);

        rReserve0 = _handleReport(token0, aReserve0, token0Managed, lToken0Managed);
        rReserve1 = _handleReport(token1, aReserve1, token1Managed, lToken1Managed);

        token0Managed = lToken0Managed;
        token1Managed = lToken1Managed;
    }

    function _managerCallback() internal {
        if (address(assetManager) == address(0)) {
            return;
        }
        assetManager.afterLiquidityEvent();
    }

    function adjustManagement(int256 token0Change, int256 token1Change) external {
        require(msg.sender == address(assetManager), "AMP: AUTH_NOT_MANAGER");
        require(token0Change != type(int256).min && token1Change != type(int256).min, "AMP: CAST_WOULD_OVERFLOW");

        if (token0Change > 0) {
            uint104 lDelta = uint104(uint256(int256(token0Change)));
            token0Managed += lDelta;
            token0.transfer(msg.sender, lDelta);
        } else if (token0Change < 0) {
            uint104 lDelta = uint104(uint256(int256(-token0Change)));

            // solhint-disable-next-line reentrancy
            token0Managed -= lDelta;

            token0.transferFrom(msg.sender, address(this), lDelta);
        }

        if (token1Change > 0) {
            uint104 lDelta = uint104(uint256(int256(token1Change)));

            // solhint-disable-next-line reentrancy
            token1Managed += lDelta;

            token1.transfer(msg.sender, lDelta);
        } else if (token1Change < 0) {
            uint104 lDelta = uint104(uint256(int256(-token1Change)));

            // solhint-disable-next-line reentrancy
            token1Managed -= lDelta;

            token1.transferFrom(msg.sender, address(this), lDelta);
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                            ORACLE WRITING

    <WHAT TO SAY>

    //////////////////////////////////////////////////////////////////////////*/

    event OracleCallerUpdated(address oldCaller, address newCaller);
    event MaxChangeRateUpdated(uint256 oldMaxChangePerSecond, uint256 newMaxChangePerSecond);

    // 100 basis points per second which is 60% per minute
    uint256 internal constant MAX_CHANGE_PER_SEC = 0.01e18;
    string internal constant ALLOWED_CHANGE_NAME = "Shared::allowedChangePerSecond";
    string internal constant ORACLE_CALLER_NAME = "Shared::oracleCaller";

    Observation[65_536] internal _observations;

    // maximum allowed rate of change of price per second
    // to mitigate oracle manipulation attacks in the face of post-merge ETH
    // TODO: allowedChangePerSecond -> maxChangeRate
    uint256 public allowedChangePerSecond;
    // TODO: setAllowedChangePerSecond -> setMaxChangeRate
    uint256 public prevClampedPrice;

    address public oracleCaller;

    function observation(uint256 aIndex) external view returns (Observation memory rObservation) {
        require(msg.sender == oracleCaller, "OW: NOT_ORACLE_CALLER");
        rObservation = _observations[aIndex];
    }

    function updateOracleCaller() public {
        address lNewCaller = factory.read(ORACLE_CALLER_NAME).toAddress();
        if (lNewCaller != oracleCaller) {
            emit OracleCallerUpdated(oracleCaller, lNewCaller);
            oracleCaller = lNewCaller;
        }
    }

    function setAllowedChangePerSecond(uint256 aAllowedChangePerSecond) public onlyFactory {
        require(
            0 < aAllowedChangePerSecond && aAllowedChangePerSecond <= MAX_CHANGE_PER_SEC,
            "OW: INVALID_CHANGE_PER_SECOND"
        );
        emit MaxChangeRateUpdated(allowedChangePerSecond, aAllowedChangePerSecond);
        allowedChangePerSecond = aAllowedChangePerSecond;
    }

    function _calcClampedPrice(uint256 aCurrRawPrice, uint256 aPrevClampedPrice, uint256 aTimeElapsed)
        internal
        virtual
        returns (uint256 rClampedPrice, int112 rClampedLogPrice)
    {
        if (aPrevClampedPrice == 0) {
            return (aCurrRawPrice, int112(LogCompression.toLowResLog(aCurrRawPrice)));
        }

        if (stdMath.percentDelta(aCurrRawPrice, aPrevClampedPrice) > allowedChangePerSecond * aTimeElapsed) {
            // clamp the price
            if (aCurrRawPrice > aPrevClampedPrice) {
                rClampedPrice = aPrevClampedPrice * (1e18 + (allowedChangePerSecond * aTimeElapsed)) / 1e18;
            } else {
                assert(aPrevClampedPrice > aCurrRawPrice);
                rClampedPrice = aPrevClampedPrice * (1e18 - (allowedChangePerSecond * aTimeElapsed)) / 1e18;
            }
            rClampedLogPrice = int112(LogCompression.toLowResLog(rClampedPrice));
        } else {
            rClampedPrice = aCurrRawPrice;
            rClampedLogPrice = int112(LogCompression.toLowResLog(aCurrRawPrice));
        }
    }

    function _updateOracle(uint256 aReserve0, uint256 aReserve1, uint32 aTimeElapsed, uint32 aTimestampLast)
        internal
        virtual;

    // performs a transfer, if it fails, it attempts to retrieve assets from the
    // AssetManager before retrying the transfer
    function _checkedTransfer(ERC20 aToken, address aDestination, uint256 aAmount, uint256 aReserve0, uint256 aReserve1)
        internal
    {
        if (!_safeTransfer(address(aToken), aDestination, aAmount)) {
            uint256 tokenOutManaged = aToken == token0 ? token0Managed : token1Managed;
            uint256 reserveOut = aToken == token0 ? aReserve0 : aReserve1;
            if (reserveOut - tokenOutManaged < aAmount) {
                assetManager.returnAsset(aToken == token0, aAmount - (reserveOut - tokenOutManaged));
                require(_safeTransfer(address(aToken), aDestination, aAmount), "RP: TRANSFER_FAILED");
            } else {
                revert("RP: TRANSFER_FAILED");
            }
        }
    }

    // update reserves and, on the first call per block, price and liq accumulators
    function _updateAndUnlock(
        uint256 aBalance0,
        uint256 aBalance1,
        uint104 aReserve0,
        uint104 aReserve1,
        uint32 aBlockTimestampLast
    ) internal {
        require(aBalance0 <= type(uint104).max && aBalance1 <= type(uint104).max, "RP: OVERFLOW");

        uint32 lBlockTimestamp = uint32(_currentTime());
        uint32 lTimeElapsed;
        unchecked {
            lTimeElapsed = lBlockTimestamp - aBlockTimestampLast; // overflow is desired
        }
        if (lTimeElapsed > 0 && aReserve0 != 0 && aReserve1 != 0) {
            _updateOracle(aReserve0, aReserve1, lTimeElapsed, aBlockTimestampLast);
        }

        _slot0.reserve0 = uint104(aBalance0);
        _slot0.reserve1 = uint104(aBalance1);
        _writeSlot0Timestamp(lBlockTimestamp, false);

        emit Sync(uint104(aBalance0), uint104(aBalance1));
    }
}
