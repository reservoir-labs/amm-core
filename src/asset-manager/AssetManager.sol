pragma solidity 0.8.13;

import { ReentrancyGuard } from "@openzeppelin/security/ReentrancyGuard.sol";
import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/interfaces/IERC20.sol";

import { IAssetManager } from "src/interfaces/IAssetManager.sol";
import { IComptroller } from "src/interfaces/IComptroller.sol";
import { IUniswapV2Pair } from "src/interfaces/IUniswapV2Pair.sol";
import { CErc20Interface, CTokenInterface } from "src/interfaces/CErc20Interface.sol";

contract AssetManager is IAssetManager, Ownable, ReentrancyGuard {
    event FundsInvested(address pair, address token, address market, uint256 amount);
    event FundsDivested(address pair, address token, address market, uint256 amount);

    /// @dev maps from the address of the pairs to a token (of the pair) to a market
    mapping(address => mapping(address => address)) public markets;

    IComptroller public immutable compoundComptroller;

    constructor(address aComptroller) {
        require(aComptroller != address(0), "COMPTROLLER ADDRESS ZERO");
        compoundComptroller = IComptroller(aComptroller);
    }

    /// @dev returns the balance of the token managed by various markets in the native precision
    function getBalance(address aOwner, address aToken) external view returns (uint112 rTokenBalance) {
        CTokenInterface lMarket = CTokenInterface(markets[aOwner][aToken]);

        if (address(lMarket) == address(0)) {
            return 0;
        }

        // the exchange rate is scaled by 1e18
        uint256 lExchangeRate = lMarket.exchangeRateStored();
        uint256 lCTokenBalance = lMarket.balanceOf(address(this));

        rTokenBalance += uint112(lCTokenBalance * lExchangeRate / 1e18);
    }

    function adjustManagement(
        address aPair,
        int256 aAmount0Change,
        int256 aAmount1Change,
        uint256 token0MarketIndex,
        uint256 token1MarketIndex
    ) external nonReentrant onlyOwner {
        require(
            aAmount0Change != type(int256).min && aAmount1Change != type(int256).min,
            "cast would overflow"
        );

        IERC20 token0 = IERC20(IUniswapV2Pair(aPair).token0());
        IERC20 token1 = IERC20(IUniswapV2Pair(aPair).token1());

        // if the indexes provided by the caller are out of range, it will revert
        CErc20Interface lMarket0 = CErc20Interface(compoundComptroller.allMarkets(token0MarketIndex));
        CErc20Interface lMarket1 = CErc20Interface(compoundComptroller.allMarkets(token1MarketIndex));

        require(aAmount0Change == 0 || lMarket0.underlying() == address(token0));
        require(aAmount1Change == 0 || lMarket1.underlying() == address(token1));

        // withdrawal from the market
        if (aAmount0Change < 0) {
            _doDivest(aPair, token0, uint256(-aAmount0Change), lMarket0);
        }
        if (aAmount1Change < 0) {
            _doDivest(aPair, token1, uint256(-aAmount1Change), lMarket1);
        }

        // transfer tokens to/from the pair
        IUniswapV2Pair(aPair).adjustManagement(aAmount0Change, aAmount1Change);

        // transfer the managed tokens to the destination
        if (aAmount0Change > 0) {
            _doInvest(aPair, token0, uint256(aAmount0Change), lMarket0);
        }
        if (aAmount1Change > 0) {
            _doInvest(aPair, token1, uint256(aAmount1Change), lMarket1);
        }
    }

    function _doDivest(address aPair, IERC20 aToken, uint256 aAmountDecrease, CErc20Interface aMarket) private {
        uint256 lRes = aMarket.redeemUnderlying(aAmountDecrease);
        require(lRes == 0, "REDEEM DID NOT SUCCEED");

        aToken.approve(aPair, aAmountDecrease);

        // todo: to update the markets mapping (set to address 0) if there are no more receipt tokens left
        // but this could be tricky due to dust amounts left
        // especially when using redeemUnderlying instead of redeem

        emit FundsDivested(aPair, address(aToken), address(aMarket), aAmountDecrease);
    }

    function _doInvest(address aPair, IERC20 aToken, uint256 aAmountIncrease, CErc20Interface aMarket) private {
        require(aToken.balanceOf(address(this)) == aAmountIncrease, "TOKEN AMOUNT MISMATCH");

        if (markets[aPair][address(aToken)] == address(0)) {
            markets[aPair][address(aToken)] = address(aMarket);
        }
        else {
            require(markets[aPair][address(aToken)] == address(aMarket), "ANOTHER MARKET ACTIVE");
        }

        aToken.approve(address(aMarket), aAmountIncrease);
        uint256 res = aMarket.mint(aAmountIncrease);
        require(res == 0, "MINT DID NOT SUCCEED");

        emit FundsInvested(aPair, address(aToken), address(aMarket), aAmountIncrease);
    }
}
