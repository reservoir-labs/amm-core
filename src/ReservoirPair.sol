// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import { stdMath } from "forge-std/Test.sol";
import { SafeCast } from "@openzeppelin/utils/math/SafeCast.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

import { FactoryStoreLib } from "src/libraries/FactoryStore.sol";
import { Bytes32Lib } from "src/libraries/Bytes32.sol";
import { LogCompression } from "src/libraries/LogCompression.sol";

import { IAssetManager } from "src/interfaces/IAssetManager.sol";
import { IAssetManagedPair } from "src/interfaces/IAssetManagedPair.sol";

import { GenericFactory } from "src/GenericFactory.sol";
import { ReservoirERC20, ERC20 } from "src/ReservoirERC20.sol";

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

abstract contract ReservoirPair is IAssetManagedPair, ReservoirERC20 {
    using FactoryStoreLib for GenericFactory;
    using Bytes32Lib for bytes32;
    using SafeCast for uint256;

    event SwapFeeChanged(uint256 oldSwapFee, uint256 newSwapFee);
    event CustomSwapFeeChanged(uint256 oldCustomSwapFee, uint256 newCustomSwapFee);
    event PlatformFeeChanged(uint256 oldPlatformFee, uint256 newPlatformFee);
    event CustomPlatformFeeChanged(uint256 oldCustomPlatformFee, uint256 newCustomPlatformFee);
    event Mint(address indexed sender, uint256 amount0, uint256 amount1);
    event Burn(address indexed sender, uint256 amount0, uint256 amount1);
    event Swap(address indexed sender, bool zeroForOne, uint256 amountIn, uint256 amountOut, address indexed to);
    event Sync(uint104 reserve0, uint104 reserve1);

    string internal constant PLATFORM_FEE_TO_NAME = "Shared::platformFeeTo";
    string private constant PLATFORM_FEE_NAME = "Shared::platformFee";
    // TODO: Rename from defaultRecoverer given its always read on recovery?
    string private constant RECOVERER_NAME = "Shared::defaultRecoverer";
    bytes4 private constant TRANSFER = bytes4(keccak256("transfer(address,uint256)"));

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
    uint128 public immutable token0PrecisionMultiplier;
    uint128 public immutable token1PrecisionMultiplier;

    Slot0 internal _slot0 = Slot0({ reserve0: 0, reserve1: 0, packedTimestamp: 0, index: type(uint16).max });

    uint256 public swapFee;
    uint256 public customSwapFee = type(uint256).max;
    bytes32 internal immutable swapFeeName;

    uint256 public platformFee;
    uint256 public customPlatformFee = type(uint256).max;

    modifier onlyFactory() {
        require(msg.sender == address(factory), "P: FORBIDDEN");
        _;
    }

    constructor(ERC20 aToken0, ERC20 aToken1, string memory aSwapFeeName, bool aNormalPair) {
        factory = GenericFactory(msg.sender);
        token0 = aToken0;
        token1 = aToken1;

        token0PrecisionMultiplier = aNormalPair ? uint128(10) ** (18 - aToken0.decimals()) : 0;
        token1PrecisionMultiplier = aNormalPair ? uint128(10) ** (18 - aToken1.decimals()) : 0;
        swapFeeName = keccak256(abi.encodePacked(aSwapFeeName));

        if (aNormalPair) {
            updateSwapFee();
            updatePlatformFee();
            updateOracleCaller();
            setMaxChangeRate(factory.read(MAX_CHANGE_RATE_NAME).toUint256());
        }
    }

    /*//////////////////////////////////////////////////////////////////////////

                            IMMUTABLE GETTERS

    Let's StableMintBurn override the immutables to instead make a call to
    address(this) so the action is delegatecall safe.

    //////////////////////////////////////////////////////////////////////////*/

    function _token0() internal view virtual returns (ERC20) {
        return token0;
    }

    function _token1() internal view virtual returns (ERC20) {
        return token1;
    }

    function _token0PrecisionMultiplier() internal view virtual returns (uint128) {
        return token0PrecisionMultiplier;
    }

    function _token1PrecisionMultiplier() internal view virtual returns (uint128) {
        return token1PrecisionMultiplier;
    }

    /*//////////////////////////////////////////////////////////////////////////

                            SLOT0 & RESERVES

    //////////////////////////////////////////////////////////////////////////*/

    function _currentTime() internal view returns (uint32) {
        return uint32(block.timestamp % 2 ** 31);
    }

    function _splitSlot0Timestamp(uint32 aRawTimestamp) internal pure returns (uint32 rTimestamp, bool rLocked) {
        rLocked = aRawTimestamp >> 31 == 1;
        rTimestamp = aRawTimestamp & 0x7FFFFFFF;
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

    // update reserves and, on the first call per block, price and liq accumulators
    function _updateAndUnlock(
        uint256 aBalance0,
        uint256 aBalance1,
        uint256 aReserve0,
        uint256 aReserve1,
        uint32 aBlockTimestampLast
    ) internal {
        require(aBalance0 <= type(uint104).max && aBalance1 <= type(uint104).max, "RP: OVERFLOW");
        require(aReserve0 <= type(uint104).max && aReserve1 <= type(uint104).max, "RP: OVERFLOW");

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
        (uint256 lReserve0, uint256 lReserve1, uint32 lBlockTimestampLast,) = _lockAndLoad();
        (lReserve0, lReserve1) = _syncManaged(lReserve0, lReserve1);

        _updateAndUnlock(_totalToken0(), _totalToken1(), lReserve0, lReserve1, lBlockTimestampLast);
    }

    /// @notice Force balances to match reserves.
    function skim(address aTo) external {
        (uint256 lReserve0, uint256 lReserve1, uint32 lBlockTimestampLast,) = _lockAndLoad();

        _checkedTransfer(_token0(), aTo, _totalToken0() - lReserve0, lReserve0, lReserve1);
        _checkedTransfer(_token1(), aTo, _totalToken1() - lReserve1, lReserve0, lReserve1);
        _unlock(lBlockTimestampLast);
    }

    /*//////////////////////////////////////////////////////////////////////////

                            ADMIN ACTIONS

    //////////////////////////////////////////////////////////////////////////*/

    function setCustomSwapFee(uint256 aCustomSwapFee) external onlyFactory {
        // we assume the factory won't spam events, so no early check & return
        emit CustomSwapFeeChanged(customSwapFee, aCustomSwapFee);
        customSwapFee = aCustomSwapFee;

        updateSwapFee();
    }

    function setCustomPlatformFee(uint256 aCustomPlatformFee) external onlyFactory {
        emit CustomPlatformFeeChanged(customPlatformFee, aCustomPlatformFee);
        customPlatformFee = aCustomPlatformFee;

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

    function recoverToken(address aToken) external {
        address _recoverer = factory.read(RECOVERER_NAME).toAddress();
        require(aToken != address(_token0()) && aToken != address(_token1()), "P: INVALID_TOKEN_TO_RECOVER");
        require(_recoverer != address(0), "P: RECOVERER_ZERO_ADDRESS");

        uint256 _amountToRecover = ERC20(aToken).balanceOf(address(this));

        _safeTransfer(aToken, _recoverer, _amountToRecover);
    }

    /*//////////////////////////////////////////////////////////////////////////

                            TRANSFER HELPERS

    //////////////////////////////////////////////////////////////////////////*/

    function _safeTransfer(address aToken, address aTo, uint256 aValue) internal returns (bool) {
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory data) = aToken.call(abi.encodeWithSelector(TRANSFER, aTo, aValue));
        return success && (data.length == 0 || abi.decode(data, (bool)));
    }

    // performs a transfer, if it fails, it attempts to retrieve assets from the
    // AssetManager before retrying the transfer
    function _checkedTransfer(ERC20 aToken, address aDestination, uint256 aAmount, uint256 aReserve0, uint256 aReserve1)
        internal
    {
        if (!_safeTransfer(address(aToken), aDestination, aAmount)) {
            bool lIsToken0 = aToken == _token0();
            uint256 lTokenOutManaged = lIsToken0 ? token0Managed : token1Managed;
            uint256 lReserveOut = lIsToken0 ? aReserve0 : aReserve1;

            if (lReserveOut - lTokenOutManaged < aAmount) {
                assetManager.returnAsset(lIsToken0, aAmount - (lReserveOut - lTokenOutManaged));
                require(_safeTransfer(address(aToken), aDestination, aAmount), "RP: TRANSFER_FAILED");
            } else {
                revert("RP: TRANSFER_FAILED");
            }
        }
    }

    /// @dev Mints LP tokens - should be called via the router after transferring tokens.
    /// The router must ensure that sufficient LP tokens are minted by using the return value.
    function mint(address aTo) external virtual returns (uint256 liquidity);

    /// @dev Burns LP tokens sent to this contract. The router must ensure that the user gets sufficient output tokens.
    function burn(address aTo) external virtual returns (uint256 amount0, uint256 amount1);

    /// @notice Swaps one token for another. The router must prefund this contract and ensure there isn't too much
    ///         slippage.
    /// @param aAmount positive to indicate token0, negative to indicate token1
    /// @param aInOrOut true to indicate exact amount in, false to indicate exact amount out
    /// @param aTo address to send the output token and leftover input tokens, callee for the flash swap
    /// @param aData calls to with this data, in the event of a flash swap
    function swap(int256 aAmount, bool aInOrOut, address aTo, bytes calldata aData)
        external
        virtual
        returns (uint256 rAmountOut);

    /*//////////////////////////////////////////////////////////////////////////
                            ASSET MANAGEMENT

    Asset management is supported via a two-way interface. The pool is able to
    ask the current asset manager for the latest view of the balances. In turn
    the asset manager can move assets in/out of the pool. This section
    implements the pool side of the equation. The manager's side is abstracted
    behind the IAssetManager interface.

    //////////////////////////////////////////////////////////////////////////*/

    event ProfitReported(ERC20 token, uint256 amount);
    event LossReported(ERC20 token, uint256 amount);

    IAssetManager public assetManager;

    function setManager(IAssetManager manager) external onlyFactory {
        require(token0Managed == 0 && token1Managed == 0, "AMP: AM_STILL_ACTIVE");
        assetManager = manager;
    }

    uint104 public token0Managed;
    uint104 public token1Managed;

    function _totalToken0() internal view returns (uint256) {
        return _token0().balanceOf(address(this)) + uint256(token0Managed);
    }

    function _totalToken1() internal view returns (uint256) {
        return _token1().balanceOf(address(this)) + uint256(token1Managed);
    }

    function _handleReport(ERC20 aToken, uint256 aReserve, uint256 aPrevBalance, uint256 aNewBalance)
        private
        returns (uint256 rUpdatedReserve)
    {
        if (aNewBalance > aPrevBalance) {
            // report profit
            uint256 lProfit = aNewBalance - aPrevBalance;

            emit ProfitReported(aToken, lProfit);

            rUpdatedReserve = aReserve + lProfit;
        } else if (aNewBalance < aPrevBalance) {
            // report loss
            uint256 lLoss = aPrevBalance - aNewBalance;

            emit LossReported(aToken, lLoss);

            rUpdatedReserve = aReserve - lLoss;
        } else {
            // Balances are equal, return the original reserve.
            rUpdatedReserve = aReserve;
        }
    }

    function _syncManaged(uint256 aReserve0, uint256 aReserve1)
        internal
        returns (uint256 rReserve0, uint256 rReserve1)
    {
        if (address(assetManager) == address(0)) {
            return (aReserve0, aReserve1);
        }

        ERC20 lToken0 = _token0();
        ERC20 lToken1 = _token1();

        uint256 lToken0Managed = assetManager.getBalance(this, lToken0);
        uint256 lToken1Managed = assetManager.getBalance(this, lToken1);

        rReserve0 = _handleReport(lToken0, aReserve0, token0Managed, lToken0Managed);
        rReserve1 = _handleReport(lToken1, aReserve1, token1Managed, lToken1Managed);

        token0Managed = lToken0Managed.toUint104();
        token1Managed = lToken1Managed.toUint104();
    }

    function _managerCallback() internal {
        if (address(assetManager) == address(0)) {
            return;
        }
        assetManager.afterLiquidityEvent();
    }

    function adjustManagement(int256 aToken0Change, int256 aToken1Change) external {
        require(msg.sender == address(assetManager), "AMP: AUTH_NOT_MANAGER");

        if (aToken0Change > 0) {
            uint104 lDelta = uint256(aToken0Change).toUint104();
            token0Managed += lDelta;
            SafeTransferLib.safeTransfer(address(_token0()), msg.sender, lDelta);
        } else if (aToken0Change < 0) {
            uint104 lDelta = uint256(-aToken0Change).toUint104();

            // solhint-disable-next-line reentrancy
            token0Managed -= lDelta;

            SafeTransferLib.safeTransferFrom(address(_token0()), msg.sender, address(this), lDelta);
        }

        if (aToken1Change > 0) {
            uint104 lDelta = uint256(aToken1Change).toUint104();

            // solhint-disable-next-line reentrancy
            token1Managed += lDelta;

            SafeTransferLib.safeTransfer(address(_token1()), msg.sender, lDelta);
        } else if (aToken1Change < 0) {
            uint104 lDelta = uint256(-aToken1Change).toUint104();

            // solhint-disable-next-line reentrancy
            token1Managed -= lDelta;

            SafeTransferLib.safeTransferFrom(address(_token1()), msg.sender, address(this), lDelta);
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                            ORACLE WRITING

    Our oracle implementation records both the raw price and clamped price.
    The clamped price mechanism is introduced by Reservoir to counter the possibility
    of oracle manipulation as ETH transitions to PoS when validators can control
    multiple blocks in a row. See also https://chainsecurity.com/oracle-manipulation-after-merge/

    //////////////////////////////////////////////////////////////////////////*/

    event OracleCallerUpdated(address oldCaller, address newCaller);
    event MaxChangeRateUpdated(uint256 oldMaxChangePerSecond, uint256 newMaxChangePerSecond);

    // 100 basis points per second which is 60% per minute
    uint256 internal constant MAX_CHANGE_PER_SEC = 0.01e18;
    string internal constant MAX_CHANGE_RATE_NAME = "Shared::maxChangeRate";
    string internal constant ORACLE_CALLER_NAME = "Shared::oracleCaller";

    Observation[65_536] internal _observations;

    // maximum allowed rate of change of price per second
    // to mitigate oracle manipulation attacks in the face of post-merge ETH
    uint256 public maxChangeRate;
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

    function setMaxChangeRate(uint256 aMaxChangeRate) public onlyFactory {
        require(0 < aMaxChangeRate && aMaxChangeRate <= MAX_CHANGE_PER_SEC, "OW: INVALID_CHANGE_PER_SECOND");
        emit MaxChangeRateUpdated(maxChangeRate, aMaxChangeRate);
        maxChangeRate = aMaxChangeRate;
    }

    function _calcClampedPrice(uint256 aCurrRawPrice, uint256 aPrevClampedPrice, uint256 aTimeElapsed)
        internal
        virtual
        returns (uint256 rClampedPrice, int112 rClampedLogPrice)
    {
        if (aPrevClampedPrice == 0) {
            return (aCurrRawPrice, int112(LogCompression.toLowResLog(aCurrRawPrice)));
        }

        if (stdMath.percentDelta(aCurrRawPrice, aPrevClampedPrice) > maxChangeRate * aTimeElapsed) {
            // clamp the price
            if (aCurrRawPrice > aPrevClampedPrice) {
                rClampedPrice = aPrevClampedPrice * (1e18 + (maxChangeRate * aTimeElapsed)) / 1e18;
            } else {
                assert(aPrevClampedPrice > aCurrRawPrice);
                rClampedPrice = aPrevClampedPrice * (1e18 - (maxChangeRate * aTimeElapsed)) / 1e18;
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
}
