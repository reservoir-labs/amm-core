pragma solidity ^0.8.0;

import { GenericFactory } from "src/GenericFactory.sol";
import { IReservoirERC20 } from "src/interfaces/IReservoirERC20.sol";

interface IPair is IReservoirERC20 {
    // solhint-disable-next-line func-name-mixedcase
    function MINIMUM_LIQUIDITY() external pure returns (uint256);
    // solhint-disable-next-line func-name-mixedcase
    function FEE_ACCURACY() external pure returns (uint256);
    // solhint-disable-next-line func-name-mixedcase
    function MAX_PLATFORM_FEE() external pure returns (uint256);
    // solhint-disable-next-line func-name-mixedcase
    function MAX_SWAP_FEE() external pure returns (uint256);

    function factory() external returns (GenericFactory);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves()
        external
        view
        returns (uint104 reserve0, uint104 reserve1, uint32 blockTimestampLast, uint16 index);

    function mint(address to) external returns (uint256 liquidity);
    function burn(address to) external returns (uint256 amount0, uint256 amount1);

    /// @notice Swaps one token for another. The router must prefund this contract and ensure there isn't too much
    ///         slippage.
    /// @param amount positive to indicate token0, negative to indicate token1
    /// @param inOrOut true to indicate exact amount in, false to indicate exact amount out
    /// @param to address to send the output token and leftover input tokens, callee for the flash swap
    /// @param data calls to with this data, in the event of a flash swap
    function swap(int256 amount, bool inOrOut, address to, bytes calldata data) external returns (uint256 amountOut);

    function skim(address to) external;
    function sync() external;
    function recoverToken(address token) external;

    function swapFee() external view returns (uint256);
    function platformFee() external view returns (uint256);
    function customSwapFee() external view returns (uint256);
    function customPlatformFee() external view returns (uint256);
    function setCustomSwapFee(uint256 _customSwapFee) external;
    function setCustomPlatformFee(uint256 _customPlatformFee) external;
    function updateSwapFee() external;
    function updatePlatformFee() external;

    event Mint(address indexed sender, uint256 amount0, uint256 amount1);
    event Burn(address indexed sender, uint256 amount0, uint256 amount1);
    event Swap(address indexed sender, bool zeroForOne, uint256 amountIn, uint256 amountOut, address indexed to);
    event Sync(uint104 reserve0, uint104 reserve1);

    event SwapFeeChanged(uint256 oldSwapFee, uint256 newSwapFee);
    event CustomSwapFeeChanged(uint256 oldCustomSwapFee, uint256 newCustomSwapFee);
    event PlatformFeeChanged(uint256 oldPlatformFee, uint256 newPlatformFee);
    event CustomPlatformFeeChanged(uint256 oldCustomPlatformFee, uint256 newCustomPlatformFee);
}
