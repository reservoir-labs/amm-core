pragma solidity 0.8.13;

import { ReentrancyGuard } from "@openzeppelin/security/ReentrancyGuard.sol";
import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/interfaces/IERC20.sol";

import { IAssetManager } from "src/interfaces/IAssetManager.sol";
import { IPoolAddressesProvider } from "src/interfaces/aave/IPoolAddressesProvider.sol";
import { IPool } from "src/interfaces/aave/IPool.sol";
import { IAaveProtocolDataProvider } from "src/interfaces/aave/IAaveProtocolDataProvider.sol";
import { IConstantProductPair } from "src/interfaces/IConstantProductPair.sol";

contract AaveManager is IAssetManager, Ownable, ReentrancyGuard
{
    event FundsInvested(address pair, address token, uint256 shares);
    event FundsDivested(address pair, address token, uint256 shares);

    /// @dev tracks how many aToken each pair+token owns
    mapping(address => mapping(address => uint256)) public shares;

    // @dev for each aToken, tracks the total number of shares issued
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

        IERC20 lToken0 = IERC20(IConstantProductPair(aPair).token0());
        IERC20 lToken1 = IERC20(IConstantProductPair(aPair).token1());

        // withdraw from the market
        if (aAmount0Change < 0) {
            _doDivest(aPair, lToken0, uint256(-aAmount0Change));
        }
        if (aAmount1Change < 0) {
            _doDivest(aPair, lToken1, uint256(-aAmount1Change));
        }

        // transfer tokens to/from the pair
        IConstantProductPair(aPair).adjustManagement(aAmount0Change, aAmount1Change);

        // transfer the managed tokens to the destination
        if (aAmount0Change > 0) {
            _doInvest(aPair, lToken0, uint256(aAmount0Change));
        }
        if (aAmount1Change > 0) {
            _doInvest(aPair, lToken1, uint256(aAmount1Change));
        }
    }

    function _doDivest(address aPair, IERC20 aToken, uint256 aAmount) private {
        uint256 lShares = _updateShares(aPair, address(aToken), aAmount, false);
        pool.withdraw(address(aToken), aAmount, address(this));
        emit FundsDivested(aPair, address(aToken), lShares);

        aToken.approve(aPair, aAmount);
    }

    function _doInvest(address aPair, IERC20 aToken, uint256 aAmount) private {
        require(aToken.balanceOf(address(this)) == aAmount, "AM: TOKEN_AMOUNT_MISMATCH");

        uint256 lShares = _updateShares(aPair, address(aToken), aAmount, true);
        aToken.approve(address(pool), aAmount);
        pool.supply(address(aToken), aAmount, address(this), 0);
        emit FundsInvested(aPair, address(aToken), lShares);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                CALLBACKS FROM PAIR
    //////////////////////////////////////////////////////////////////////////*/

    function mintCallback() external {
        IConstantProductPair lPair = IConstantProductPair(msg.sender);
        address lToken0 = lPair.token0();
        address lToken1 = lPair.token1();

        // if after minting there is too many unmanaged tokens, invest some
        uint112 lToken0Managed = _getBalance(address(lPair), lToken0);
        uint112 lToken1Managed = _getBalance(address(lPair), lToken1);

        (uint112 lReserve0, uint112 lReserve1, ) = lPair.getReserves();

        // if less than 50% (or some threshold) is managed
        if (lReserve0 > (lToken0Managed * 2)) {
            // put some into management, target 50%
        }

        if (lReserve1 > (lToken1Managed * 2)) {
            // put some into management, target 50%
        }
    }

    function burnCallback() external {
        // if after burning there is too many managed tokens, divest some
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

    function _updateShares(address aPair, address aToken, uint256 aAmount, bool increase) private returns (uint256 rShares) {
        address lAaveToken = _getATokenAddress(aToken);
        rShares = aAmount * 1e18 / _getExchangeRate(lAaveToken);
        if (increase) {
            shares[aPair][aToken] += rShares;
            totalShares[lAaveToken] += rShares;
        }
        else {
            shares[aPair][aToken] -= rShares;
            totalShares[lAaveToken] -= rShares;
        }
    }

    function _getATokenAddress(address aToken) private view returns (address rATokenAddress) {
        (rATokenAddress , ,) = dataProvider.getReserveTokensAddresses(aToken);
    }
}
