pragma solidity 0.8.13;

import { ReentrancyGuard } from "@openzeppelin/security/ReentrancyGuard.sol";
import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/interfaces/IERC20.sol";

import { IAssetManager } from "src/interfaces/IAssetManager.sol";
import { IUniswapV2Pair } from "src/interfaces/IUniswapV2Pair.sol";
import { CErc20Interface, CTokenInterface } from "src/interfaces/CErc20Interface.sol";

contract AssetManager is IAssetManager, Ownable, ReentrancyGuard {
    event FundsInvested(address pair, uint256 amount, address counterParty);
    event FundsReturned(address pair, uint256 amount, address counterParty);

    /// @dev maps from the address of the pairs to a token (of the pair) to an array of counterparties
    mapping(address => mapping(address => address[])) public strategies;

    /// @dev to track if the strategy for the given pair and token has been registered before
    mapping(address => mapping(address => mapping(address => bool))) registered;

    constructor() {}

    /// @dev returns the balance of the token managed by various strategies in the native precision
    function getBalance(address aOwner, address aToken) external view returns (uint112 tokenBalance) {
        address[] memory lStrategies = strategies[aOwner][aToken];
        for (uint i = 0; i < lStrategies.length; ++i) {
            address a = lStrategies[i];
            // the exchange rate is scaled by 1e18
            uint256 exchangeRate = CTokenInterface(a).exchangeRateStored();
            uint256 cTokenBalance = IERC20(a).balanceOf(address(this));

            tokenBalance += uint112(cTokenBalance * exchangeRate / 1e18);
        }
    }

    function adjustManagement(address aPair, int256 aAmount0Change, int256 aAmount1Change, address aCounterParty) external nonReentrant onlyOwner {
        require(
            aAmount0Change != type(int256).min && aAmount1Change != type(int256).min,
            "cast would overflow"
        );

        IERC20 token0 = IERC20(IUniswapV2Pair(aPair).token0());
        IERC20 token1 = IERC20(IUniswapV2Pair(aPair).token1());

        // withdrawal from the counterparty
        if (aAmount0Change < 0) {
            uint256 amount = uint256(-aAmount0Change);
            uint256 res = CErc20Interface(aCounterParty).redeemUnderlying(amount);
            require(res == 0, "REDEEM DID NOT SUCCEED");

            token0.approve(aPair, amount);

            emit FundsReturned(aPair, amount, aCounterParty);
        }
        if (aAmount1Change < 0) {
            uint256 amount = uint256(-aAmount1Change);
            uint256 res = CErc20Interface(aCounterParty).redeemUnderlying(amount);
            require(res == 0, "REDEEM DID NOT SUCCEED");

            token1.approve(aPair, amount);

            emit FundsReturned(aPair, amount, aCounterParty);
        }

        // transfer tokens to/from the pair
        IUniswapV2Pair(aPair).adjustManagement(aAmount0Change, aAmount1Change);

        // transfer the managed tokens to the destination
        if (aAmount0Change > 0) {
            uint256 amount = uint256(aAmount0Change);
            require(token0.balanceOf(address(this)) == amount, "TOKEN0 AMOUNT MISMATCH");
            token0.approve(aCounterParty, amount);
            uint256 res = CErc20Interface(aCounterParty).mint(amount);
            require(res == 0, "MINT DID NOT SUCCEED");

            emit FundsInvested(aPair, amount, aCounterParty);

            if (!registered[aPair][address(token0)][aCounterParty]) {
                strategies[aPair][address(token0)].push(aCounterParty);
                registered[aPair][address(token0)][aCounterParty] = true;
            }
        }
        if (aAmount1Change > 0) {
            uint256 amount = uint256(aAmount1Change);
            require(token1.balanceOf(address(this)) == amount, "TOKEN1 AMOUNT MISMATCH");
            token1.approve(aCounterParty, amount);
            uint256 res = CErc20Interface(aCounterParty).mint(amount);
            require(res == 0, "MINT DID NOT SUCCEED");

            emit FundsInvested(aPair, amount, aCounterParty);

            if (!registered[aPair][address(token1)][aCounterParty]) {
                strategies[aPair][address(token1)].push(aCounterParty);
                registered[aPair][address(token1)][aCounterParty] = true;
            }
        }
    }
}
