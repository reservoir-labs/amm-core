pragma solidity 0.8.13;

import { ReentrancyGuard } from "@openzeppelin/security/ReentrancyGuard.sol";
import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/interfaces/IERC20.sol";

import { IAssetManager } from "src/interfaces/IAssetManager.sol";
import { IUniswapV2Pair } from "src/interfaces/IUniswapV2Pair.sol";
import { CErc20Interface } from "src/interfaces/CErc20Interface.sol";
import { IStrategy } from "src/interfaces/IStrategy.sol";

contract AssetManager is IAssetManager, Ownable, ReentrancyGuard {

    // are two distinct events necessary? Or can we just have one generic one
    // for both investing and divesting
    event FundsInvested(address pair, uint256 amount, address counterParty);
    event FundsReturned(address pair, uint256 amount, address counterParty);

    /// @dev maps from the address of the pairs to a token (of the pair) to an array of strategies
    mapping(address => mapping(address => IStrategy[])) public strategies;

    constructor() {}

    function getBalance(address aOwner, address aToken) external returns (uint112 tokenBalance) {
        IStrategy[] memory lStrategies = strategies[aOwner][aToken];
        for (uint i = 0; i < lStrategies.length; ++i) {
            tokenBalance += lStrategies[i].getBalance();
        }
    }

    // optimization: could we cut the intermediate step of transferring to the AM first before transferring to the destination
    // and instead transfer it from the pair to the destination instead?
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
        // safe to cast int256 to uint256?
        // not needed as the pair will perform the transfer
        if (aAmount0Change > 0) {
            uint256 amount = uint256(aAmount0Change);
            require(token0.balanceOf(address(this)) == amount, "TOKEN0 AMOUNT MISMATCH");
            token0.approve(aCounterParty, amount);
            uint256 res = CErc20Interface(aCounterParty).mint(amount);
            require(res == 0, "MINT DID NOT SUCCEED");

            emit FundsInvested(aPair, amount, aCounterParty);
        }
        if (aAmount1Change > 0) {
            uint256 amount = uint256(aAmount1Change);
            require(token1.balanceOf(address(this)) == amount, "TOKEN1 AMOUNT MISMATCH");
            token1.approve(aCounterParty, amount);
            uint256 res = CErc20Interface(aCounterParty).mint(amount);
            require(res == 0, "MINT DID NOT SUCCEED");

            emit FundsInvested(aPair, amount, aCounterParty);
        }
    }
}
