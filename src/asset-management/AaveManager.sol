// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import { ReentrancyGuard } from "solmate/utils/ReentrancyGuard.sol";
import { Owned } from "solmate/auth/Owned.sol";
import { ERC20 } from "solmate/tokens/ERC20.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

import { IAssetManagedPair } from "src/interfaces/IAssetManagedPair.sol";
import { IAssetManager } from "src/interfaces/IAssetManager.sol";
import { IPoolAddressesProvider } from "src/interfaces/aave/IPoolAddressesProvider.sol";
import { IPool } from "src/interfaces/aave/IPool.sol";
import { IAaveProtocolDataProvider } from "src/interfaces/aave/IAaveProtocolDataProvider.sol";

contract AaveManager is IAssetManager, Owned(msg.sender), ReentrancyGuard {
    using FixedPointMathLib for uint256;

    event FundsInvested(IAssetManagedPair pair, ERC20 token, uint256 shares);
    event FundsDivested(IAssetManagedPair pair, ERC20 token, uint256 shares);

    /// @dev tracks how many aToken each pair+token owns
    mapping(IAssetManagedPair => mapping(ERC20 => uint256)) public shares;

    /// @dev for each aToken, tracks the total number of shares issued
    mapping(ERC20 => uint256) public totalShares;

    /// @dev percentage of the pool's assets, above and below which
    /// the manager will divest the shortfall and invest the excess
    uint256 public upperThreshold = 70;
    uint256 public lowerThreshold = 30;

    /// @dev this contract itself is immutable and is the source of truth for all relevant addresses for aave
    IPoolAddressesProvider public immutable addressesProvider;

    /// @dev we interact with this address for deposits and withdrawals
    IPool public pool;

    /// @dev this address is not permanent, aave can change this address to upgrade to a new impl
    IAaveProtocolDataProvider public dataProvider;

    /// @dev when set to true by the owner, it will only allow divesting but not investing by the pairs in this mode
    /// to facilitate replacement of asset managers to newer versions
    bool public windDownMode;

    constructor(address aPoolAddressesProvider) {
        require(aPoolAddressesProvider != address(0), "AM: PROVIDER_ADDRESS_ZERO");
        addressesProvider = IPoolAddressesProvider(aPoolAddressesProvider);
        updatePoolAddress();
        updateDataProviderAddress();
    }

    function updatePoolAddress() public onlyOwner {
        address lNewPool = addressesProvider.getPool();
        require(lNewPool != address(0), "AM: POOL_ADDRESS_ZERO");
        pool = IPool(lNewPool);
    }

    function updateDataProviderAddress() public onlyOwner {
        address lNewDataProvider = addressesProvider.getPoolDataProvider();
        require(lNewDataProvider != address(0), "AM: DATA_PROVIDER_ADDRESS_ZERO");
        dataProvider = IAaveProtocolDataProvider(lNewDataProvider);
    }

    function setWindDownMode(bool aWindDown) external onlyOwner {
        windDownMode = aWindDown;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    GET BALANCE
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev returns the balance of the token managed by various markets in the native precision
    function getBalance(IAssetManagedPair aOwner, ERC20 aToken) external view returns (uint256 rTokenBalance) {
        return _getBalance(aOwner, aToken);
    }

    function _getBalance(IAssetManagedPair aOwner, ERC20 aToken) private view returns (uint256 rTokenBalance) {
        ERC20 lAaveToken = _getATokenAddress(aToken);
        uint256 lTotalShares = totalShares[lAaveToken];
        if (lTotalShares == 0) {
            return 0;
        }
        rTokenBalance = shares[aOwner][aToken] * ERC20(lAaveToken).balanceOf(address(this)) / lTotalShares;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                ADJUST MANAGEMENT
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice if token0 or token1 does not have a market in AAVE, the tokens will not be transferred
    function adjustManagement(IAssetManagedPair aPair, int256 aAmount0Change, int256 aAmount1Change)
        external
        onlyOwner
    {
        _adjustManagement(aPair, aAmount0Change, aAmount1Change);
    }

    function _adjustManagement(IAssetManagedPair aPair, int256 aAmount0Change, int256 aAmount1Change)
        private
        nonReentrant
    {
        require(aAmount0Change != type(int256).min && aAmount1Change != type(int256).min, "AM: CAST_WOULD_OVERFLOW");

        ERC20 lToken0 = aPair.token0();
        ERC20 lToken1 = aPair.token1();

        ERC20 lToken0AToken = _getATokenAddress(lToken0);
        ERC20 lToken1AToken = _getATokenAddress(lToken1);

        // do not do anything if there isn't a market for the token
        if (address(lToken0AToken) == address(0)) {
            aAmount0Change = 0;
        }
        if (address(lToken1AToken) == address(0)) {
            aAmount1Change = 0;
        }

        if (windDownMode) {
            if (aAmount0Change > 0) {
                aAmount0Change = 0;
            }
            if (aAmount1Change > 0) {
                aAmount1Change = 0;
            }
        }

        // withdraw from the market
        if (aAmount0Change < 0) {
            _doDivest(aPair, lToken0, lToken0AToken, uint256(-aAmount0Change));
        }
        if (aAmount1Change < 0) {
            _doDivest(aPair, lToken1, lToken1AToken, uint256(-aAmount1Change));
        }

        // transfer tokens to/from the pair
        aPair.adjustManagement(aAmount0Change, aAmount1Change);

        // transfer the managed tokens to the destination
        if (aAmount0Change > 0) {
            _doInvest(aPair, lToken0, lToken0AToken, uint256(aAmount0Change));
        }
        if (aAmount1Change > 0) {
            _doInvest(aPair, lToken1, lToken1AToken, uint256(aAmount1Change));
        }
    }

    function _doDivest(IAssetManagedPair aPair, ERC20 aToken, ERC20 aAaveToken, uint256 aAmount) private {
        uint256 lShares = _decreaseShares(aPair, aToken, aAaveToken, aAmount);
        pool.withdraw(address(aToken), aAmount, address(this));
        emit FundsDivested(aPair, aToken, lShares);
        SafeTransferLib.safeApprove(address(aToken), address(aPair), aAmount);
    }

    function _doInvest(IAssetManagedPair aPair, ERC20 aToken, ERC20 aAaveToken, uint256 aAmount) private {
        require(aToken.balanceOf(address(this)) == aAmount, "AM: TOKEN_AMOUNT_MISMATCH");
        uint256 lShares = _increaseShares(aPair, aToken, aAaveToken, aAmount);
        SafeTransferLib.safeApprove(address(aToken), address(pool), aAmount);

        pool.supply(address(aToken), aAmount, address(this), 0);
        emit FundsInvested(aPair, aToken, lShares);
    }

    function setUpperThreshold(uint256 aUpperThreshold) external onlyOwner {
        require(aUpperThreshold <= 100 && aUpperThreshold > lowerThreshold, "AM: INVALID_THRESHOLD");
        upperThreshold = aUpperThreshold;
    }

    function setLowerThreshold(uint256 aLowerThreshold) external onlyOwner {
        require(aLowerThreshold <= 100 && aLowerThreshold < upperThreshold, "AM: INVALID_THRESHOLD");
        lowerThreshold = aLowerThreshold;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                CALLBACKS FROM PAIR
    //////////////////////////////////////////////////////////////////////////*/

    function afterLiquidityEvent() external {
        IAssetManagedPair lPair = IAssetManagedPair(msg.sender);
        ERC20 lToken0 = lPair.token0();
        ERC20 lToken1 = lPair.token1();
        (uint256 lReserve0, uint256 lReserve1,,) = lPair.getReserves();

        uint256 lToken0Managed = _getBalance(lPair, lToken0);
        uint256 lToken1Managed = _getBalance(lPair, lToken1);

        int256 lAmount0Change = _calculateChangeAmount(lReserve0, lToken0Managed);
        int256 lAmount1Change = _calculateChangeAmount(lReserve1, lToken1Managed);

        _adjustManagement(lPair, lAmount0Change, lAmount1Change);
    }

    function returnAsset(bool aToken0, uint256 aAmount) external {
        require(aAmount > 0, "AM: ZERO_AMOUNT_REQUESTED");
        IAssetManagedPair lPair = IAssetManagedPair(msg.sender);
        int256 lAmount0Change = -int256(aToken0 ? aAmount : 0);
        int256 lAmount1Change = -int256(aToken0 ? 0 : aAmount);
        assert(lAmount0Change < 0 || lAmount1Change < 0);
        _adjustManagement(lPair, lAmount0Change, lAmount1Change);
    }

    function _calculateChangeAmount(uint256 aReserve, uint256 aManaged) internal view returns (int256 rAmountChange) {
        uint256 lRatio = aManaged * 100 / aReserve;
        if (lRatio < lowerThreshold) {
            rAmountChange = int256(aReserve * ((lowerThreshold + upperThreshold) / 2) / 100 - aManaged);
            assert(rAmountChange > 0);
        } else if (lRatio > upperThreshold) {
            rAmountChange = int256(aReserve * ((lowerThreshold + upperThreshold) / 2) / 100) - int256(aManaged);
            assert(rAmountChange < 0);
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                                HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev expresses the exchange rate in terms of how many aTokens per share, scaled by 1e18
    function _getExchangeRate(ERC20 aAaveToken) private view returns (uint256 rExchangeRate) {
        uint256 lTotalShares = totalShares[aAaveToken];
        if (lTotalShares == 0) {
            return 1e18;
        }
        rExchangeRate = aAaveToken.balanceOf(address(this)).divWad(lTotalShares);
    }

    function _increaseShares(IAssetManagedPair aPair, ERC20 aToken, ERC20 aAaveToken, uint256 aAmount)
        private
        returns (uint256 rShares)
    {
        rShares = aAmount.divWad(_getExchangeRate(aAaveToken));
        shares[aPair][aToken] += rShares;
        totalShares[aAaveToken] += rShares;
    }

    function _decreaseShares(IAssetManagedPair aPair, ERC20 aToken, ERC20 aAaveToken, uint256 aAmount)
        private
        returns (uint256 rShares)
    {
        rShares = aAmount.divWad(_getExchangeRate(aAaveToken));
        shares[aPair][aToken] -= rShares;
        totalShares[aAaveToken] -= rShares;
    }

    /// @notice returns the address of the AAVE token.
    /// If an AAVE token doesn't exist for the asset, returns address 0
    function _getATokenAddress(ERC20 aToken) private view returns (ERC20) {
        (address lATokenAddress,,) = dataProvider.getReserveTokensAddresses(address(aToken));
        return ERC20(lATokenAddress);
    }
}
