pragma solidity 0.8.13;

import { ReentrancyGuard } from "@openzeppelin/security/ReentrancyGuard.sol";
import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/interfaces/IERC20.sol";

import { IAssetManager } from "src/interfaces/IAssetManager.sol";
import { IPoolAddressesProvider } from "src/interfaces/IPoolAddressesProvider.sol";
import { IPool } from "src/interfaces/IPool.sol";
import { IUniswapV2Pair } from "src/interfaces/IUniswapV2Pair.sol";

contract AaveManager is IAssetManager, Ownable, ReentrancyGuard
{
    event FundsInvested(address pair, address token, address market, uint256 amount);
    event FundsDivested(address pair, address token, address market, uint256 amount);

    /// @dev maps from the address of the pairs to a token (of the pair) to a market
    /// here we do not delete entries as we are only integrating with AAVE
    /// and that there is one and only one address for each underlying token
    /// so once an entry is written it will not be overwritten
    mapping(address => mapping(address => address)) public markets;

    /// @dev tracks how many aToken each pair+token owns
    mapping(address => mapping(address => uint256)) public shares;

    IPool public immutable pool;

    constructor(address aPoolAddressesProvider) {
        require(aPoolAddressesProvider != address(0), "COMPTROLLER ADDRESS ZERO");
        pool = IPool(IPoolAddressesProvider(aPoolAddressesProvider).getPool());
    }

    /// @dev returns the balance of the token managed by various markets in the native precision
    function getBalance(address aOwner, address aToken) external view returns (uint112 rTokenBalance) {
        return _getBalance(aOwner, aToken);
    }

    function adjustManagement(
        address aPair,
        int256 aAmount0Change,
        int256 aAmount1Change
//        uint256 aToken0MarketIndex,
//        uint256 aToken1MarketIndex
    ) external nonReentrant onlyOwner {
        require(
            aAmount0Change != type(int256).min && aAmount1Change != type(int256).min,
            "cast would overflow"
        );

        IERC20 lToken0 = IERC20(IUniswapV2Pair(aPair).token0());
        IERC20 lToken1 = IERC20(IUniswapV2Pair(aPair).token1());

//        require(aAmount0Change == 0 || address(lMarket0.underlying()) == address(lToken0), "WRONG MARKET FOR TOKEN");
//        require(aAmount1Change == 0 || address(lMarket1.underlying()) == address(lToken1), "WRONG MARKET FOR TOKEN");

        // withdrawal from the market
//        if (aAmount0Change < 0) {
//            _doDivest(aPair, lToken0, lMarket0, uint256(-aAmount0Change));
//        }
//        if (aAmount1Change < 0) {
//            _doDivest(aPair, lToken1, lMarket1, uint256(-aAmount1Change));
//        }
//
//        // transfer tokens to/from the pair
//        IUniswapV2Pair(aPair).adjustManagement(aAmount0Change, aAmount1Change);
//
//        // transfer the managed tokens to the destination
//        if (aAmount0Change > 0) {
//            _doInvest(aPair, lToken0, lMarket0, uint256(aAmount0Change));
//        }
//        if (aAmount1Change > 0) {
//            _doInvest(aPair, lToken1, lMarket1, uint256(aAmount1Change));
//        }
    }

    function _getBalance(address aOwner, address aToken) private view returns (uint112 rTokenBalance) {
        uint256 lShares = shares[aOwner][aToken];

        if (lShares == 0) {
            return 0;
        }

        // the exchange rate is scaled by 1e18
//        uint256 lExchangeRate = LibCompound.viewExchangeRate(markets[aOwner][aToken]);

//        rTokenBalance = uint112(lShares * lExchangeRate / 1e18);
    }

    function _doDivest(address aPair, IERC20 aToken, IPool aMarket, uint256 aAmount) private {
//        uint256 lPrevCTokenBalance = aMarket.balanceOf(address(this));
//
//        aMarket.withdraw(address(aToken), aAmount, address(this));
//
//        uint256 lCurrentCTokenBalance = aMarket.balanceOf(address(this));
//        // if attempting to redeem more than the pair+token's share, this will revert
//        shares[aPair][address(aToken)] -= lPrevCTokenBalance - lCurrentCTokenBalance;
//
//        aToken.approve(aPair, aAmount);
//
//        emit FundsDivested(aPair, address(aToken), address(aMarket), aAmount);
    }

    function _doInvest(address aPair, IERC20 aToken, IPool aMarket, uint256 aAmount) private {
//        require(aToken.balanceOf(address(this)) == aAmount, "TOKEN AMOUNT MISMATCH");
//
//        if (address(markets[aPair][address(aToken)]) == address(0)) {
//            markets[aPair][address(aToken)] = aMarket;
//        }
//        else {
//            require(markets[aPair][address(aToken)] == aMarket, "ANOTHER MARKET ACTIVE");
//        }
//
//        aToken.approve(address(aMarket), aAmount);
//
//        uint256 lPrevCTokenBalance = aMarket.balanceOf(address(this));
//
//        aMarket.supply(address(aToken), aAmount, address(this), 0);
//
//        uint256 lCurrentCTokenBalance = aMarket.balanceOf(address(this));
//        shares[aPair][address(aToken)] += lCurrentCTokenBalance - lPrevCTokenBalance;
//
//        emit FundsInvested(aPair, address(aToken), address(aMarket), aAmount);
    }
}
