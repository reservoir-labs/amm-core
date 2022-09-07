pragma solidity 0.8.13;

import "@openzeppelin/interfaces/IERC20.sol";

import "src/interfaces/IAssetManagedPair.sol";
import "src/interfaces/IAssetManager.sol";

import "src/GenericFactory.sol";

abstract contract AssetManagedPair is IAssetManagedPair {

    GenericFactory public immutable factory;
    address public immutable token0;
    address public immutable token1;

    uint112 internal reserve0;
    uint112 internal reserve1;
    uint32  internal blockTimestampLast;

    constructor(address aToken0, address aToken1) {
        factory = GenericFactory(msg.sender);
        token0  = aToken0;
        token1  = aToken1;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                ASSET MANAGER
    //////////////////////////////////////////////////////////////////////////*/

    IAssetManager public assetManager;

    function setManager(IAssetManager manager) external onlyFactory {
        require(token0Managed == 0 && token1Managed == 0, "AMP: AM_STILL_ACTIVE");
        assetManager = manager;
    }

    modifier onlyManager() {
        require(msg.sender == address(assetManager), "AMP: AUTH_NOT_ASSET_MANAGER");
        _;
    }

    modifier onlyFactory() {
        require(msg.sender == address(factory), "AMP: FORBIDDEN");
        _;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                ASSET MANAGEMENT

    Asset management is supported via a two -way interface. The pool is able to
    ask the current asset manager for the latest view of the balances. In turn
    the asset manager can move assets in/ out of the pool. This section
    implements the pool - side of the equation. The manager's side is abstracted
    behind the IAssetManager interface.

    //////////////////////////////////////////////////////////////////////////*/

    uint112 public token0Managed;
    uint112 public token1Managed;

    function _totalToken0() internal view returns (uint256) {
        return IERC20(token0).balanceOf(address(this)) + uint256(token0Managed);
    }

    function _totalToken1() internal view returns (uint256) {
        return IERC20(token1).balanceOf(address(this)) + uint256(token1Managed);
    }

    event ProfitReported(address token, uint112 amount);
    event LossReported(address token, uint112 amount);

    function _handleReport(address token, uint112 prevBalance, uint112 newBalance) internal {
        if (newBalance > prevBalance) {
            // report profit
            uint112 lProfit = newBalance - prevBalance;

            emit ProfitReported(token, lProfit);

            token == token0
                ? reserve0 += lProfit
                : reserve1 += lProfit;
        }
        else if (newBalance < prevBalance) {
            // report loss
            uint112 lLoss = prevBalance - newBalance;

            emit LossReported(token, lLoss);

            token == token0
                ? reserve0 -= lLoss
                : reserve1 -= lLoss;
        }
        // else do nothing balance is equal
    }

    function _syncManaged() internal {
        if (address(assetManager) == address(0)) {
            return;
        }

        uint112 lToken0Managed = assetManager.getBalance(this, token0);
        uint112 lToken1Managed = assetManager.getBalance(this, token1);

        _handleReport(token0, token0Managed, lToken0Managed);
        _handleReport(token1, token1Managed, lToken1Managed);

        token0Managed = lToken0Managed;
        token1Managed = lToken1Managed;
    }

    function _managerCallback() internal {
        if (address(assetManager) == address(0)) {
            return;
        }
        assetManager.afterLiquidityEvent();
    }

    function adjustManagement(int256 token0Change, int256 token1Change) external onlyManager {
        require(
            token0Change != type(int256).min && token1Change != type(int256).min,
            "AMP: CAST_WOULD_OVERFLOW"
        );

        if (token0Change > 0) {
            uint112 lDelta = uint112(uint256(int256(token0Change)));
            token0Managed += lDelta;
            IERC20(token0).transfer(address(assetManager), lDelta);
        }
        else if (token0Change < 0) {
            uint112 lDelta = uint112(uint256(int256(-token0Change)));

            // solhint-disable-next-line reentrancy
            token0Managed -= lDelta;

            IERC20(token0).transferFrom(address(assetManager), address(this), lDelta);
        }

        if (token1Change > 0) {
            uint112 lDelta = uint112(uint256(int256(token1Change)));

            // solhint-disable-next-line reentrancy
            token1Managed += lDelta;

            IERC20(token1).transfer(address(assetManager), lDelta);
        }
        else if (token1Change < 0) {
            uint112 lDelta = uint112(uint256(int256(-token1Change)));

            // solhint-disable-next-line reentrancy
            token1Managed -= lDelta;

            IERC20(token1).transferFrom(address(assetManager), address(this), lDelta);
        }

        _update(
            _totalToken0(),
            _totalToken1(),
            reserve0,
            reserve1
        );
    }

    function _update(uint256 aTotalToken0, uint256 aTotalToken1, uint112 aReserve0, uint112 aReserve1) internal virtual;
}
