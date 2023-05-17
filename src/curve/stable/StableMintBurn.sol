// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import {
    ERC20,
    Math,
    Bytes32Lib,
    FactoryStoreLib,
    StableMath,
    IGenericFactory,
    StablePair
} from "src/curve/stable/StablePair.sol";

contract StableMintBurn is StablePair {
    using FactoryStoreLib for IGenericFactory;
    using Bytes32Lib for bytes32;
    using Math for uint256;

    string private constant PAIR_SWAP_FEE_NAME = "SP::swapFee";

    // solhint-disable-next-line no-empty-blocks
    constructor() StablePair(ERC20(address(0)), ERC20(address(0))) {
        // no additional initialization logic is required as all constructor logic is in StablePair
    }

    function token0() public view override returns (ERC20) {
        return this.token0();
    }

    function token1() public view override returns (ERC20) {
        return this.token1();
    }

    function token0PrecisionMultiplier() public view override returns (uint128) {
        return this.token0PrecisionMultiplier();
    }

    function token1PrecisionMultiplier() public view override returns (uint128) {
        return this.token1PrecisionMultiplier();
    }

    /// @dev This fee is charged to cover for `swapFee` when users add unbalanced liquidity.
    /// multiplications will not phantom overflow given the following conditions:
    /// 1. reserves are <= uint104
    /// 2. aAmount0 and aAmount1 <= uint104 as it would revert anyway at _updateAndUnlock if above uint104
    /// 3. swapFee <= 0.02e6
    function _nonOptimalMintFee(uint256 aAmount0, uint256 aAmount1, uint256 aReserve0, uint256 aReserve1)
        internal
        view
        returns (uint256 rToken0Fee, uint256 rToken1Fee)
    {
        if (aReserve0 == 0 || aReserve1 == 0) return (0, 0);
        uint256 amount1Optimal = aAmount0 * aReserve1 / aReserve0;

        if (amount1Optimal <= aAmount1) {
            rToken1Fee = (swapFee * (aAmount1 - amount1Optimal)) / (2 * FEE_ACCURACY);
        } else {
            uint256 amount0Optimal = aAmount1 * aReserve0 / aReserve1;
            rToken0Fee = swapFee * (aAmount0 - amount0Optimal) / (2 * FEE_ACCURACY);
        }
        require(rToken0Fee <= type(uint104).max && rToken1Fee <= type(uint104).max, "SP: NON_OPTIMAL_FEE_TOO_LARGE");
    }

    function mint(address aTo) external override returns (uint256 rLiquidity) {
        // NB: Must sync management PNL before we load reserves.
        (uint256 lReserve0, uint256 lReserve1, uint32 lBlockTimestampLast,) = _lockAndLoad();
        (lReserve0, lReserve1) = _syncManaged(lReserve0, lReserve1);

        uint256 lBalance0 = _totalToken0();
        uint256 lBalance1 = _totalToken1();

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
            // will only phantom overflow when lTotalSupply and lNewLiq is in the range of uint128 which will only happen if:
            // 1. both tokens have 0 decimals (1e18 is 60 bits) and the amounts are each around 68 bits
            // 2. both tokens have 6 decimals (1e12 is 40 bits) and the amounts are each around 88 bits
            // in which case the mint will fail anyway
            rLiquidity = (lNewLiq - lOldLiq) * lTotalSupply / lOldLiq;
        }
        require(rLiquidity != 0, "SP: INSUFFICIENT_LIQ_MINTED");
        _mint(aTo, rLiquidity);

        // Casting is safe as the max invariant would be 2 * uint104 * uint60 (in the case of tokens
        // with 0 decimal places).
        // Which results in 112 + 60 + 1 = 173 bits.
        // Which fits into uint192.
        lastInvariant = uint192(lNewLiq);
        lastInvariantAmp = _getCurrentAPrecise();

        emit Mint(msg.sender, lAmount0, lAmount1);

        _updateAndUnlock(lBalance0, lBalance1, lReserve0, lReserve1, lBlockTimestampLast);
        _managerCallback();
    }

    function burn(address aTo) external override returns (uint256 rAmount0, uint256 rAmount1) {
        // NB: Must sync management PNL before we load reserves.
        (uint256 lReserve0, uint256 lReserve1, uint32 lBlockTimestampLast,) = _lockAndLoad();
        (lReserve0, lReserve1) = _syncManaged(lReserve0, lReserve1);

        uint256 liquidity = balanceOf[address(this)];

        (uint256 lTotalSupply,) = _mintFee(lReserve0, lReserve1);

        rAmount0 = liquidity.mulDiv(lReserve0, lTotalSupply);
        rAmount1 = liquidity.mulDiv(lReserve1, lTotalSupply);

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

    function swap(int256, bool, address, bytes calldata) external pure override returns (uint256) {
        revert("SMB: IMPOSSIBLE");
    }

    function _mintFee(uint256 aReserve0, uint256 aReserve1) internal returns (uint256 rTotalSupply, uint256 rD) {
        bool lFeeOn = platformFee > 0;
        rTotalSupply = totalSupply;
        rD = StableMath._computeLiquidityFromAdjustedBalances(
            aReserve0 * token0PrecisionMultiplier(), aReserve1 * token1PrecisionMultiplier(), 2 * lastInvariantAmp
        );
        if (lFeeOn) {
            uint256 lDLast = lastInvariant;
            if (lDLast != 0) {
                if (rD > lDLast) {
                    // @dev `platformFee` % of increase in liquidity.
                    uint256 lPlatformFee = platformFee;
                    // will not phantom overflow as rTotalSupply is max 128 bits. and (rD - lDLast) is usually within 70 bits and lPlatformFee is max 1e6 (20 bits)
                    uint256 lNumerator = rTotalSupply * (rD - lDLast) * lPlatformFee;
                    // will not phantom overflow as FEE_ACCURACY and lPlatformFee are max 1e6 (20 bits), and rD and lDLast are max 128 bits
                    uint256 lDenominator = (FEE_ACCURACY - lPlatformFee) * rD + lPlatformFee * lDLast;
                    uint256 lPlatformShares = lNumerator / lDenominator;

                    if (lPlatformShares != 0) {
                        address lPlatformFeeTo = this.factory().read(PLATFORM_FEE_TO_NAME).toAddress();

                        _mint(lPlatformFeeTo, lPlatformShares);
                        rTotalSupply += lPlatformShares;
                    }
                }
            }
        }
    }
}
