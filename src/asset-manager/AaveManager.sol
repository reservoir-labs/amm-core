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

    /// @dev this contract itself is immutable and is the source of truth for all relevant addresses for aave
    IPoolAddressesProvider public immutable addressesProvider;

    /// @dev this address will never change since it is a proxy and can be upgraded
    IPool public immutable pool;

    /// @dev this address is not permanent, aave can change this address to upgrade to a new impl
    IAaveProtocolDataProvider public dataProvider;

    constructor(address aPoolAddressesProvider) {
        require(aPoolAddressesProvider != address(0), "COMPTROLLER ADDRESS ZERO");
        addressesProvider = IPoolAddressesProvider(aPoolAddressesProvider);
        pool = IPool(addressesProvider.getPool());
        dataProvider = IAaveProtocolDataProvider(addressesProvider.getPoolDataProvider());
    }

    /// @dev returns the balance of the token managed by various markets in the native precision
    function getBalance(address aOwner, address aToken) external view returns (uint112 rTokenBalance) {
        return _getBalance(aOwner, aToken);
    }

    function adjustManagement(
        address aPair,
        int256 aAmount0Change,
        int256 aAmount1Change
    ) external nonReentrant onlyOwner {
        require(
            aAmount0Change != type(int256).min && aAmount1Change != type(int256).min,
            "cast would overflow"
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

    function _getBalance(address aOwner, address aToken) private view returns (uint112 rTokenBalance) {
        rTokenBalance = uint112(shares[aOwner][aToken]);
    }

    function _doDivest(address aPair, IERC20 aToken, uint256 aAmount) private {
        (address lATokenAddress , ,) = dataProvider.getReserveTokensAddresses(address(aToken));
        IERC20 lAaveToken = IERC20(lATokenAddress);

        uint256 lPrevATokenBalance = lAaveToken.balanceOf(address(this));
        pool.withdraw(address(aToken), aAmount, address(this));
        uint256 lCurrATokenBalance = lAaveToken.balanceOf(address(this));

        // if attempting to redeem more than the pair+token's share, this will revert
        shares[aPair][address(aToken)] -= lPrevATokenBalance - lCurrATokenBalance;

        aToken.approve(aPair, aAmount);

        emit FundsDivested(aPair, address(aToken), address(lATokenAddress), aAmount);
    }

    function _doInvest(address aPair, IERC20 aToken, uint256 aAmount) private {
        require(aToken.balanceOf(address(this)) == aAmount, "TOKEN AMOUNT MISMATCH");

        (address lATokenAddress , ,) = dataProvider.getReserveTokensAddresses(address(aToken));

        aToken.approve(address(pool), aAmount);

        uint256 lPrevATokenBalance = IERC20(lATokenAddress).balanceOf(address(this));
        pool.supply(address(aToken), aAmount, address(this), 0);
        uint256 lCurrATokenBalance = IERC20(lATokenAddress).balanceOf(address(this));

        shares[aPair][address(aToken)] += lCurrATokenBalance - lPrevATokenBalance;

        emit FundsInvested(aPair, address(aToken), address(lATokenAddress), aAmount);
    }
}
