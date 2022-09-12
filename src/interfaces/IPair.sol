pragma solidity 0.8.13;

import { GenericFactory } from "src/GenericFactory.sol";

interface IPair {
    // solhint-disable-next-line func-name-mixedcase
    function MINIMUM_LIQUIDITY() external pure returns (uint);

    function factory() external returns (GenericFactory);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function skim(address to) external;
    function sync() external;

    function mint(address to) external returns (uint256 liquidity);
    function burn(address to) external returns (uint256 amount0, uint256 amount1);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;

    function swapFee() external view returns (uint256);
    function platformFee() external view returns (uint256);
    function customSwapFee() external view returns (uint256);
    function customPlatformFee() external view returns (uint256);
    function setCustomSwapFee(uint256 _customSwapFee) external;
    function setCustomPlatformFee(uint256 _customPlatformFee) external;
    function updateSwapFee() external;
    function updatePlatformFee() external;

    function recoverToken(address token) external;

    event Mint(address indexed sender, uint256 amount0, uint256 amount1);
    event Burn(address indexed sender, uint256 amount0, uint256 amount1, address indexed to);
    event Swap(
        address indexed sender,
        uint256 amount0In,
        uint256 amount1In,
        uint256 amount0Out,
        uint256 amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);
    event SwapFeeChanged(uint oldSwapFee, uint newSwapFee);
    event CustomSwapFeeChanged(uint oldCustomSwapFee, uint newCustomSwapFee);
    event PlatformFeeChanged(uint oldPlatformFee, uint newPlatformFee);
    event CustomPlatformFeeChanged(uint oldCustomPlatformFee, uint newCustomPlatformFee);
}
