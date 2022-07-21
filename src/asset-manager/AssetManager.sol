pragma solidity 0.8.13;

import { ReentrancyGuard } from "@openzeppelin/security/ReentrancyGuard.sol";
import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/interfaces/IERC20.sol";

import { IAssetManager } from "src/interfaces/IAssetManager.sol";
import { IUniswapV2Pair } from "src/interfaces/IUniswapV2Pair.sol";
import { CErc20Interface, CTokenInterface } from "src/interfaces/CErc20Interface.sol";

contract AssetManager is IAssetManager, Ownable, ReentrancyGuard {
    event FundsInvested(address pair, address token, address counterParty, uint256 amount);
    event FundsDivested(address pair, address token, address counterParty, uint256 amount);

    /// @dev maps from the address of the pairs to a token (of the pair) to an array of counterparties
    mapping(address => mapping(address => address)) public counterparties;

    constructor() {}

    /// @dev returns the balance of the token managed by various counterparties in the native precision
    function getBalance(address aOwner, address aToken) external view returns (uint112 rTokenBalance) {
        CTokenInterface lCounterparty = CTokenInterface(counterparties[aOwner][aToken]);

        if (address(lCounterparty) == address(0)) {
            return 0;
        }

        // the exchange rate is scaled by 1e18
        uint256 lExchangeRate = lCounterparty.exchangeRateStored();
        uint256 lCTokenBalance = lCounterparty.balanceOf(address(this));

        rTokenBalance += uint112(lCTokenBalance * lExchangeRate / 1e18);
    }

    function adjustManagement(
        address aPair,
        int256 aAmount0Change,
        int256 aAmount1Change,
        address aToken0CounterParty,
        address aToken1CounterParty
    ) external nonReentrant onlyOwner {
        require(
            aAmount0Change != type(int256).min && aAmount1Change != type(int256).min,
            "cast would overflow"
        );

        IERC20 token0 = IERC20(IUniswapV2Pair(aPair).token0());
        IERC20 token1 = IERC20(IUniswapV2Pair(aPair).token1());

        // withdrawal from the counterparty
        if (aAmount0Change < 0) {
            _doDivest(aPair, token0, uint256(-aAmount0Change), aToken0CounterParty);
        }
        if (aAmount1Change < 0) {
            _doDivest(aPair, token1, uint256(-aAmount1Change), aToken1CounterParty);
        }

        // transfer tokens to/from the pair
        IUniswapV2Pair(aPair).adjustManagement(aAmount0Change, aAmount1Change);

        // transfer the managed tokens to the destination
        if (aAmount0Change > 0) {
            _doInvest(aPair, token0, uint256(aAmount0Change), aToken0CounterParty);
        }
        if (aAmount1Change > 0) {
            _doInvest(aPair, token1, uint256(aAmount1Change), aToken1CounterParty);
        }
    }

    function _doDivest(address aPair, IERC20 aToken, uint256 aAmountDecrease, address aCounterParty) private {
        uint256 lRes = CErc20Interface(aCounterParty).redeemUnderlying(aAmountDecrease);
        require(lRes == 0, "REDEEM DID NOT SUCCEED");

        aToken.approve(aPair, aAmountDecrease);

        // todo: to update the counterparties mapping (set to address 0) if there are no more receipt tokens left
        // but this could be tricky due to dust amounts left
        // especially when using redeemUnderlying instead of redeem

        emit FundsDivested(aPair, address(aToken), aCounterParty, aAmountDecrease);
    }

    function _doInvest(address aPair, IERC20 aToken, uint256 aAmountIncrease, address aCounterParty) private {
        require(aToken.balanceOf(address(this)) == aAmountIncrease, "TOKEN AMOUNT MISMATCH");

        if (counterparties[aPair][address(aToken)] == address(0)) {
            counterparties[aPair][address(aToken)] = aCounterParty;
        }
        else {
            require(counterparties[aPair][address(aToken)] == aCounterParty, "ANOTHER STRATEGY ACTIVE");
        }

        aToken.approve(aCounterParty, aAmountIncrease);
        uint256 res = CErc20Interface(aCounterParty).mint(aAmountIncrease);
        require(res == 0, "MINT DID NOT SUCCEED");

        emit FundsInvested(aPair, address(aToken), aCounterParty, aAmountIncrease);
    }
}
