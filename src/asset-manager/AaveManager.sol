pragma solidity 0.8.13;

import { ReentrancyGuard } from "@openzeppelin/security/ReentrancyGuard.sol";
import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/interfaces/IERC20.sol";

import { IAssetManager } from "src/interfaces/IAssetManager.sol";
import { IPoolAddressesProvider } from "src/interfaces/aave/IPoolAddressesProvider.sol";
import { IPool } from "src/interfaces/aave/IPool.sol";
import { IAaveProtocolDataProvider } from "src/interfaces/aave/IAaveProtocolDataProvider.sol";
import { IUniswapV2Pair } from "src/interfaces/IUniswapV2Pair.sol";

contract AaveManager is IAssetManager, Ownable, ReentrancyGuard
{
    event FundsInvested(address pair, address token, address aaveToken, uint256 amount);
    event FundsDivested(address pair, address token, address aaveToken, uint256 amount);

    /// @dev tracks how many aToken each pair+token owns
    mapping(address => mapping(address => uint256)) public shares;

    // @dev for each aToken, tracks the number of shares issued to each pair+token combo
    mapping(address => uint256) public totalShares;

    /// @dev this contract itself is immutable and is the source of truth for all relevant addresses for aave
    IPoolAddressesProvider public immutable addressesProvider;

    /// @dev this address will never change since it is a proxy and can be upgraded
    IPool public immutable pool;

    /// @dev this address is not permanent, aave can change this address to upgrade to a new impl
    IAaveProtocolDataProvider public dataProvider;

    constructor(address aPoolAddressesProvider) {
        require(aPoolAddressesProvider != address(0), "AM: PROVIDER_ADDRESS_ZERO");
        addressesProvider = IPoolAddressesProvider(aPoolAddressesProvider);
        pool = IPool(addressesProvider.getPool());
        dataProvider = IAaveProtocolDataProvider(addressesProvider.getPoolDataProvider());
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    GET BALANCE
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev returns the balance of the token managed by various markets in the native precision
    function getBalance(address aOwner, address aToken) external view returns (uint112 rTokenBalance) {
        return _getBalance(aOwner, aToken);
    }

    function _getBalance(address aOwner, address aToken) private view returns (uint112 rTokenBalance) {
        address lAaveToken = _getATokenAddress(aToken);
        uint256 lTotalShares = totalShares[lAaveToken];
        if (lTotalShares == 0) {
            return 0;
        }
        rTokenBalance = uint112(shares[aOwner][aToken] * IERC20(lAaveToken).balanceOf(address(this)) / totalShares[lAaveToken]);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                ADJUST MANAGEMENT
    //////////////////////////////////////////////////////////////////////////*/

    function adjustManagement(
        address aPair,
        int256 aAmount0Change,
        int256 aAmount1Change
    ) external nonReentrant onlyOwner {
        require(
            aAmount0Change != type(int256).min && aAmount1Change != type(int256).min,
            "AM: CAST_WOULD_OVERFLOW"
        );

        IERC20 lToken0 = IERC20(IUniswapV2Pair(aPair).token0());
        IERC20 lToken1 = IERC20(IUniswapV2Pair(aPair).token1());

        // withdraw from the market
        if (aAmount0Change < 0) {
            _doDivest(aPair, lToken0, uint256(-aAmount0Change));
        }
        if (aAmount1Change < 0) {
            _doDivest(aPair, lToken1, uint256(-aAmount1Change));
        }

        // transfer tokens to/from the pair
        IUniswapV2Pair(aPair).adjustManagement(aAmount0Change, aAmount1Change);

        // transfer the managed tokens to the destination
        if (aAmount0Change > 0) {
            _doInvest(aPair, lToken0, uint256(aAmount0Change));
        }
        if (aAmount1Change > 0) {
            _doInvest(aPair, lToken1, uint256(aAmount1Change));
        }
    }

    function _doDivest(address aPair, IERC20 aToken, uint256 aAmount) private {
        IERC20 lAaveToken = IERC20(_getATokenAddress(address(aToken)));

        _updateShares(aPair, address(aToken), address(lAaveToken), aAmount, false);
        pool.withdraw(address(aToken), aAmount, address(this));
        emit FundsDivested(aPair, address(aToken), address(lAaveToken), aAmount);

        aToken.approve(aPair, aAmount);
    }

    function _doInvest(address aPair, IERC20 aToken, uint256 aAmount) private {
        require(aToken.balanceOf(address(this)) == aAmount, "AM: TOKEN_AMOUNT_MISMATCH");
        IERC20 lAaveToken = IERC20(_getATokenAddress(address(aToken)));

        _updateShares(aPair, address(aToken), address(lAaveToken), aAmount, true);
        aToken.approve(address(pool), aAmount);
        pool.supply(address(aToken), aAmount, address(this), 0);
        emit FundsInvested(aPair, address(aToken), address(lAaveToken), aAmount);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev expresses the exchange rate in terms of how many aTokens per share, scaled by 1e18
    function _getExchangeRate(address aAaveToken) private view returns (uint256 rExchangeRate) {
        uint256 lTotalShares = totalShares[aAaveToken];
        if (lTotalShares == 0) {
            return 1e18;
        }
        rExchangeRate = IERC20(aAaveToken).balanceOf(address(this)) * 1e18 / totalShares[aAaveToken];
    }

    function _updateShares(address aPair, address aToken, address aAaveToken, uint256 aAmount, bool increase) private {
        uint256 lShares = aAmount * 1e18 / _getExchangeRate(aAaveToken);
        if (increase) {
            shares[aPair][aToken] += lShares;
            totalShares[aAaveToken] += lShares;
        }
        else {
            shares[aPair][aToken] -= lShares;
            totalShares[aAaveToken] -= lShares;
        }
    }

    function _getATokenAddress(address aToken) private view returns (address rATokenAddress) {
        (rATokenAddress , ,) = dataProvider.getReserveTokensAddresses(aToken);
    }
}
