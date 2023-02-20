// TODO: Can we reduce the nesting by deleting the parent dir?
// TODO: License
// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import { stdMath } from "forge-std/Test.sol";
import { SafeCast } from "@openzeppelin/utils/math/SafeCast.sol";

import { Bytes32Lib } from "src/libraries/Bytes32.sol";
import { FactoryStoreLib } from "src/libraries/FactoryStore.sol";
import { StableMath } from "src/libraries/StableMath.sol";
import { StableOracleMath } from "src/libraries/StableOracleMath.sol";
import { LogCompression } from "src/libraries/LogCompression.sol";

import { IAssetManager } from "src/interfaces/IAssetManager.sol";
import { IAssetManagedPair } from "src/interfaces/IAssetManagedPair.sol";
import { GenericFactory } from "src/GenericFactory.sol";
import { ReservoirERC20, ERC20 } from "src/ReservoirERC20.sol";
import { Slot0, Observation } from "src/ReservoirPair.sol";
import { StablePair, AmplificationData } from "src/curve/stable/StablePair.sol";

contract StableMintBurn is ReservoirERC20 {
    using FactoryStoreLib for GenericFactory;
    using Bytes32Lib for bytes32;
    using SafeCast for uint256;

    uint256 public constant FEE_ACCURACY = 1_000_000; // 100%
    bytes4 private constant SELECTOR = bytes4(keccak256("transfer(address,uint256)"));
    uint256 public constant MINIMUM_LIQUIDITY = 10 ** 3;
    string internal constant PLATFORM_FEE_TO_NAME = "Shared::platformFeeTo";

    event Mint(address indexed sender, uint256 amount0, uint256 amount1);
    event Burn(address indexed sender, uint256 amount0, uint256 amount1);
    event Sync(uint104 reserve0, uint104 reserve1);
    event ProfitReported(ERC20 token, uint256 amount);
    event LossReported(ERC20 token, uint256 amount);

    GenericFactory public immutable factory = GenericFactory(0x0000000000000000000000000000000000000000);
    ERC20 public immutable token0 = ERC20(0x0000000000000000000000000000000000000000);
    ERC20 public immutable token1 = ERC20(0x0000000000000000000000000000000000000000);

    uint128 public immutable token0PrecisionMultiplier = 0;
    uint128 public immutable token1PrecisionMultiplier = 0;

    // does it make a diff in terms of gas when we make the following private / public?
    // cuz it does not make a diff in terms of storage layout
    Slot0 private _slot0;

    uint256 private swapFee;
    uint256 private customSwapFee;
    uint256 private platformFee;
    uint256 private customPlatformFee;

    IAssetManager public assetManager;

    uint104 public token0Managed;
    uint104 public token1Managed;

    Observation[65_536] internal _observations;

    uint256 public maxChangeRate;
    uint256 public prevClampedPrice;
    address public oracleCaller;

    AmplificationData public ampData;

    uint192 private lastInvariant;
    uint64 private lastInvariantAmp;

    /// @dev This fee is charged to cover for `swapFee` when users add unbalanced liquidity.
    function _nonOptimalMintFee(uint256 aAmount0, uint256 aAmount1, uint256 aReserve0, uint256 aReserve1)
        internal
        view
        returns (uint256 rToken0Fee, uint256 rToken1Fee)
    {
        if (aReserve0 == 0 || aReserve1 == 0) return (0, 0);
        uint256 amount1Optimal = (aAmount0 * aReserve1) / aReserve0;

        if (amount1Optimal <= aAmount1) {
            rToken1Fee = (swapFee * (aAmount1 - amount1Optimal)) / (2 * FEE_ACCURACY);
        } else {
            uint256 amount0Optimal = (aAmount1 * aReserve0) / aReserve1;
            rToken0Fee = (swapFee * (aAmount0 - amount0Optimal)) / (2 * FEE_ACCURACY);
        }
        require(rToken0Fee <= type(uint104).max && rToken1Fee <= type(uint104).max, "SP: NON_OPTIMAL_FEE_TOO_LARGE");
    }

    function _syncManaged(uint256 aReserve0, uint256 aReserve1)
        internal
        returns (uint256 rReserve0, uint256 rReserve1)
    {
        if (address(assetManager) == address(0)) {
            return (aReserve0, aReserve1);
        }

        uint256 lToken0Managed = assetManager.getBalance(IAssetManagedPair(this), this.token0());
        uint256 lToken1Managed = assetManager.getBalance(IAssetManagedPair(this), this.token1());

        rReserve0 = _handleReport(this.token0(), aReserve0, token0Managed, lToken0Managed);
        rReserve1 = _handleReport(this.token1(), aReserve1, token1Managed, lToken1Managed);

        token0Managed = lToken0Managed.toUint104();
        token1Managed = lToken1Managed.toUint104();
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

    function _managerCallback() internal {
        if (address(assetManager) == address(0)) {
            return;
        }
        assetManager.afterLiquidityEvent();
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

    function _checkedTransfer(ERC20 aToken, address aDestination, uint256 aAmount, uint256 aReserve0, uint256 aReserve1)
        internal
    {
        if (!_safeTransfer(address(aToken), aDestination, aAmount)) {
            uint256 tokenOutManaged = aToken == this.token0() ? token0Managed : token1Managed;
            uint256 reserveOut = aToken == this.token0() ? aReserve0 : aReserve1;
            if (reserveOut - tokenOutManaged < aAmount) {
                assetManager.returnAsset(aToken == this.token0(), aAmount - (reserveOut - tokenOutManaged));
                require(_safeTransfer(address(aToken), aDestination, aAmount), "RP: TRANSFER_FAILED");
            } else {
                revert("RP: TRANSFER_FAILED");
            }
        }
    }

    function _safeTransfer(address aToken, address aTo, uint256 aValue) internal returns (bool) {
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory data) = aToken.call(abi.encodeWithSelector(SELECTOR, aTo, aValue));
        return success && (data.length == 0 || abi.decode(data, (bool)));
    }

    function mint(address aTo) external returns (uint256 rLiquidity) {
        // NB: Must sync management PNL before we load reserves.
        (uint256 lReserve0, uint256 lReserve1, uint32 lBlockTimestampLast,) = _lockAndLoad();
        (lReserve0, lReserve1) = _syncManaged(lReserve0, lReserve1);

        (uint256 lBalance0, uint256 lBalance1) = _balances();

        uint256 lNewLiq = _computeLiquidity(lBalance0, lBalance1);
        uint256 lAmount0 = lBalance0 - lReserve0;
        uint256 lAmount1 = lBalance1 - lReserve1;

        (uint256 lFee0, uint256 lFee1) = _nonOptimalMintFee(lAmount0, lAmount1, lReserve0, lReserve1);
        lReserve0 += uint104(lFee0);
        lReserve1 += uint104(lFee1);

        (uint256 lTotalSupply, uint256 lOldLiq) = _mintFee(lReserve0, lReserve1);

        if (lTotalSupply == 0) {
            require(lAmount0 > 0 && lAmount1 > 0, "SP: INVALID_AMOUNTS");
            rLiquidity = lNewLiq - MINIMUM_LIQUIDITY;
            _mint(address(0), MINIMUM_LIQUIDITY);
        } else {
            rLiquidity = ((lNewLiq - lOldLiq) * lTotalSupply) / lOldLiq;
        }
        require(rLiquidity != 0, "SP: INSUFFICIENT_LIQ_MINTED");
        _mint(aTo, rLiquidity);

        // casting is safe as the max invariant would be 2 * uint104 * uint60 (in the case of tokens with 0 decimal
        // places)
        // which results in 112 + 60 + 1 = 173 bits
        // which fits into uint192
        lastInvariant = uint192(lNewLiq);
        lastInvariantAmp = _getCurrentAPrecise();

        emit Mint(msg.sender, lAmount0, lAmount1);

        _updateAndUnlock(lBalance0, lBalance1, lReserve0, lReserve1, lBlockTimestampLast);
        _managerCallback();
    }

    function burn(address aTo) external returns (uint256 rAmount0, uint256 rAmount1) {
        // NB: Must sync management PNL before we load reserves.
        (uint256 lReserve0, uint256 lReserve1, uint32 lBlockTimestampLast,) = _lockAndLoad();
        (lReserve0, lReserve1) = _syncManaged(lReserve0, lReserve1);

        uint256 liquidity = balanceOf[address(this)];

        (uint256 lTotalSupply,) = _mintFee(lReserve0, lReserve1);

        rAmount0 = (liquidity * lReserve0) / lTotalSupply;
        rAmount1 = (liquidity * lReserve1) / lTotalSupply;

        _burn(address(this), liquidity);

        _checkedTransfer(this.token0(), aTo, rAmount0, lReserve0, lReserve1);
        _checkedTransfer(this.token1(), aTo, rAmount1, lReserve0, lReserve1);

        uint256 lBalance0 = _totalToken0();
        uint256 lBalance1 = _totalToken1();
        lastInvariant = uint192(_computeLiquidity(lBalance0, lBalance1));
        lastInvariantAmp = _getCurrentAPrecise();
        emit Burn(msg.sender, rAmount0, rAmount1);

        _updateAndUnlock(lBalance0, lBalance1, lReserve0, lReserve1, lBlockTimestampLast);
        _managerCallback();
    }

    function swap(int256, bool, address, bytes calldata) external pure returns (uint256) {
        revert("SMB: IMPOSSIBLE");
    }

    function _balances() internal view returns (uint256 rBalance0, uint256 rBalance1) {
        rBalance0 = this.token0().balanceOf(address(this)) + uint256(token0Managed);
        rBalance1 = this.token1().balanceOf(address(this)) + uint256(token1Managed);
    }

    function _totalToken0() internal view returns (uint256) {
        return this.token0().balanceOf(address(this)) + uint256(token0Managed);
    }

    function _totalToken1() internal view returns (uint256) {
        return this.token1().balanceOf(address(this)) + uint256(token1Managed);
    }

    function _mintFee(uint256 aReserve0, uint256 aReserve1) internal returns (uint256 rTotalSupply, uint256 rD) {
        bool lFeeOn = platformFee > 0;
        rTotalSupply = totalSupply;
        rD = StableMath._computeLiquidityFromAdjustedBalances(
            aReserve0 * this.token0PrecisionMultiplier(),
            aReserve1 * this.token1PrecisionMultiplier(),
            2 * lastInvariantAmp
        );
        if (lFeeOn) {
            uint256 lDLast = lastInvariant;
            if (lDLast != 0) {
                if (rD > lDLast) {
                    // @dev `platformFee` % of increase in liquidity.
                    uint256 lPlatformFee = platformFee;
                    uint256 lNumerator = rTotalSupply * (rD - lDLast) * lPlatformFee;
                    uint256 lDenominator = (FEE_ACCURACY - lPlatformFee) * rD + lPlatformFee * lDLast;
                    uint256 lPlatformShares = lNumerator / lDenominator;

                    if (lPlatformShares != 0) {
                        address lPlatformFeeTo = this.factory().read(PLATFORM_FEE_TO_NAME).toAddress();

                        _mint(lPlatformFeeTo, lPlatformShares);
                        rTotalSupply += lPlatformShares;
                    }
                }
            }
        } else if (lastInvariant != 0) {
            lastInvariant = 0;
        }
    }

    function _getCurrentAPrecise() private view returns (uint64 rCurrentA) {
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
            } else {
                uint64 rampDelta = initialA - futureA;
                rCurrentA = initialA - rampElapsed * rampDelta / rampDuration;
            }
        } else {
            rCurrentA = futureA;
        }
    }

    function _getNA() private view returns (uint256) {
        return 2 * _getCurrentAPrecise();
    }

    function _computeLiquidity(uint256 aReserve0, uint256 aReserve1) private view returns (uint256 rLiquidity) {
        unchecked {
            uint256 adjustedReserve0 = aReserve0 * this.token0PrecisionMultiplier();
            uint256 adjustedReserve1 = aReserve1 * this.token1PrecisionMultiplier();
            rLiquidity = StableMath._computeLiquidityFromAdjustedBalances(adjustedReserve0, adjustedReserve1, _getNA());
        }
    }

    function _splitSlot0Timestamp(uint32 aRawTimestamp) internal pure returns (uint32 rTimestamp, bool rLocked) {
        rLocked = aRawTimestamp >> 31 == 1;
        rTimestamp = aRawTimestamp & 0x7FFFFFFF;
    }

    function _updateOracle(uint256 aReserve0, uint256 aReserve1, uint32 aTimeElapsed, uint32 aTimestampLast)
        internal
    {
        Observation storage previous = _observations[_slot0.index];

        (uint256 currRawPrice, int112 currLogRawPrice) = StableOracleMath.calcLogPrice(
            _getCurrentAPrecise(), aReserve0 * this.token0PrecisionMultiplier(), aReserve1 * this.token1PrecisionMultiplier()
        );
        // perf: see if we can avoid using prevClampedPrice and read the two previous oracle observations
        // to figure out the previous clamped price
        (uint256 currClampedPrice, int112 currLogClampedPrice) =
        _calcClampedPrice(currRawPrice, prevClampedPrice, aTimeElapsed);
        int112 currLogLiq = StableOracleMath.calcLogLiq(aReserve0, aReserve1);
        prevClampedPrice = currClampedPrice;

    unchecked {
        int112 logAccRawPrice = previous.logAccRawPrice + currLogRawPrice * int112(int256(uint256(aTimeElapsed)));
        int56 logAccClampedPrice =
        previous.logAccClampedPrice + int56(currLogClampedPrice) * int56(int256(uint256(aTimeElapsed)));
        int56 logAccLiq = previous.logAccLiquidity + int56(currLogLiq) * int56(int256(uint256(aTimeElapsed)));
        _slot0.index += 1;
        _observations[_slot0.index] = Observation(logAccRawPrice, logAccClampedPrice, logAccLiq, aTimestampLast);
    }
    }

    function _currentTime() internal view returns (uint32) {
        return uint32(block.timestamp % 2 ** 31);
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
}
