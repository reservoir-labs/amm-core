pragma solidity 0.8.13;

import { ReentrancyGuard } from "@openzeppelin/security/ReentrancyGuard.sol";
import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/interfaces/IERC20.sol";
import { LibCompound } from "libcompound/LibCompound.sol";
import { CERC20 } from "libcompound/interfaces/CERC20.sol";

import { IAssetManager } from "src/interfaces/IAssetManager.sol";
import { IComptroller } from "src/interfaces/IComptroller.sol";
import { IUniswapV2Pair } from "src/interfaces/IUniswapV2Pair.sol";

contract AssetManager is IAssetManager, Ownable, ReentrancyGuard {
    event FundsInvested(address pair, address token, address market, uint256 amount);
    event FundsDivested(address pair, address token, address market, uint256 amount);

    /// @dev maps from the address of the pairs to a token (of the pair) to a market
    /// here we do not delete entries as we are only integrating with compound
    /// and that there is one and only one address for each underlying token
    /// so once an entry is written it will not be overwritten
    mapping(address => mapping(address => CERC20)) public markets;

    /// @dev tracks how many cTokens each pair+token owns
    mapping(address => mapping(address => uint256)) public shares;

    IComptroller public immutable compoundComptroller;

    constructor(address aComptroller) {
        require(aComptroller != address(0), "COMPTROLLER ADDRESS ZERO");
        compoundComptroller = IComptroller(aComptroller);
    }

    /// @dev returns the balance of the token managed by various markets in the native precision
    function getBalance(address aOwner, address aToken) external view returns (uint112 rTokenBalance) {
        return _getBalance(aOwner, aToken);
    }

    function adjustManagement(
        address aPair,
        int256 aAmount0Change,
        int256 aAmount1Change,
        uint256 aToken0MarketIndex,
        uint256 aToken1MarketIndex
    ) external nonReentrant onlyOwner {
        require(
            aAmount0Change != type(int256).min && aAmount1Change != type(int256).min,
            "cast would overflow"
        );

        IERC20 lToken0 = IERC20(IUniswapV2Pair(aPair).token0());
        IERC20 lToken1 = IERC20(IUniswapV2Pair(aPair).token1());

        // if the indexes provided by the caller are out of range, it will revert
        CERC20 lMarket0 = compoundComptroller.allMarkets(aToken0MarketIndex);
        CERC20 lMarket1 = compoundComptroller.allMarkets(aToken1MarketIndex);

        require(aAmount0Change == 0 || address(lMarket0.underlying()) == address(lToken0), "WRONG MARKET FOR TOKEN");
        require(aAmount1Change == 0 || address(lMarket1.underlying()) == address(lToken1), "WRONG MARKET FOR TOKEN");

        // withdrawal from the market
        if (aAmount0Change < 0) {
            _doDivest(aPair, lToken0, uint256(-aAmount0Change), lMarket0);
        }
        if (aAmount1Change < 0) {
            _doDivest(aPair, lToken1, uint256(-aAmount1Change), lMarket1);
        }

        // transfer tokens to/from the pair
        IUniswapV2Pair(aPair).adjustManagement(aAmount0Change, aAmount1Change);

        // transfer the managed tokens to the destination
        if (aAmount0Change > 0) {
            _doInvest(aPair, lToken0, uint256(aAmount0Change), lMarket0);
        }
        if (aAmount1Change > 0) {
            _doInvest(aPair, lToken1, uint256(aAmount1Change), lMarket1);
        }
    }

    function _getBalance(address aOwner, address aToken) private view returns (uint112 rTokenBalance) {
        uint256 lShare = shares[aOwner][aToken];

        if (lShare == 0) {
            return 0;
        }

        // the exchange rate is scaled by 1e18
        uint256 lExchangeRate = LibCompound.viewExchangeRate(markets[aOwner][aToken]);

        rTokenBalance = uint112(lShare * lExchangeRate / 1e18);
    }

    function _doDivest(address aPair, IERC20 aToken, uint256 aAmountDecrease, CERC20 aMarket) private {
        uint256 lPrevCTokenBalance = aMarket.balanceOf(address(this));
        require(aMarket.redeemUnderlying(aAmountDecrease) == 0, "REDEEM DID NOT SUCCEED");
        uint256 lCurrentCTokenBalance = aMarket.balanceOf(address(this));
        // if attempting to redeem more than the pair+token's share, this will revert
        shares[aPair][address(aToken)] -= lPrevCTokenBalance - lCurrentCTokenBalance;

        aToken.approve(aPair, aAmountDecrease);

        emit FundsDivested(aPair, address(aToken), address(aMarket), aAmountDecrease);
    }

    function _doInvest(address aPair, IERC20 aToken, uint256 aAmountIncrease, CERC20 aMarket) private {
        require(aToken.balanceOf(address(this)) == aAmountIncrease, "TOKEN AMOUNT MISMATCH");

        if (address(markets[aPair][address(aToken)]) == address(0)) {
            markets[aPair][address(aToken)] = aMarket;
        }
        else {
            require(markets[aPair][address(aToken)] == aMarket, "ANOTHER MARKET ACTIVE");
        }

        aToken.approve(address(aMarket), aAmountIncrease);

        uint256 lPrevCTokenBalance = aMarket.balanceOf(address(this));
        require(aMarket.mint(aAmountIncrease) == 0, "MINT DID NOT SUCCEED");
        uint256 lCurrentCTokenBalance = aMarket.balanceOf(address(this));
        shares[aPair][address(aToken)] += lCurrentCTokenBalance - lPrevCTokenBalance;

        emit FundsInvested(aPair, address(aToken), address(aMarket), aAmountIncrease);
    }
}
